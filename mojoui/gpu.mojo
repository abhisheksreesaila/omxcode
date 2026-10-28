# Run a plain Mojo function once per pixel, on the GPU (NVIDIA or AMD, via MAX).
#
#   def shade(x: Int, y: Int, width: Int, height: Int, p: Params) -> UInt32: ...
#   var gpu = Gpu()                                  # once; gpu.available() if there is one
#   var pixels = gpu.render[shade](480, 320, p).pixels
#
# The app writes only ordinary Mojo maths; this module compiles it into a GPU
# kernel and launches one GPU thread per pixel. Needs the `max` package.

from max.gpu import global_idx
from std.sys import CompilationTarget, is_defined
from max.gpu.host import DeviceContext
from std.math import ceildiv
from mojoui.clock import now_ns
from std.os import getenv
from std.memory import bitcast
from mojoui.present import Presenter, VERTEX_BYTES

# The GPU path is compiled for Linux desktops only: Apple and Android builds (built with
# -D MOJOUI_ANDROID) use the CPU path, since MAX's GPU runtime isn't linked into them.
comptime GPU_BUILD = CompilationTarget.is_linux() and not is_defined["MOJOUI_ANDROID"]()

comptime Params = SIMD[DType.float32, 4]  # four numbers your pixel function can use
comptime PixelFn = def(Int, Int, Int, Int, Params) thin -> UInt32


# (GPU kernels still take UnsafePointer in MAX 26.6; the deprecation warning is expected.)
def _pixels_kernel[f: PixelFn](dst: UnsafePointer[UInt32, MutAnyOrigin], w32: Int32, h32: Int32, p: Params):
    var w = Int(w32)
    var h = Int(h32)
    var x = Int(global_idx.x)
    var y = Int(global_idx.y)
    if x < w and y < h:
        dst.unsafe_offset(y * w + x)[] = f(x, y, w, h, p)


@fieldwise_init
struct Rendered(Copyable, Movable):
    var pixels: List[UInt32]
    var milliseconds: Float64  # time taken (GPU: kernel launch to results ready)


struct Gpu(Movable):
    """The machine's first GPU, if it has a supported one. Keep one and reuse it.

    Checks the device count first: creating a device context with no GPU present
    crashes rather than raising, so `available` must be checked (render() does).
    """

    var ctx: Optional[DeviceContext]
    var name: String
    var device: Int  # the CUDA device number (-1: none)

    def __init__(out self, use: Bool = True):
        """use=False: act as if there were no GPU (to compare with the CPU). MOJOUI_GPU_DEVICE=n picks GPU n; a desktop
        host sets it to the display's GPU (mojoui.present), so pictures can go to the screen without leaving it."""
        self.ctx = None
        self.name = "no GPU found"
        self.device = -1
        if not use:
            return
        comptime if GPU_BUILD:  # (Apple builds: the CPU path; MAX's Apple GPU runtime isn't linked)
            try:
                var count = DeviceContext.number_of_devices()
                if count > 0:
                    var want = 0
                    var env = getenv("MOJOUI_GPU_DEVICE")
                    if env != "":
                        try:
                            want = Int(env)
                        except:
                            want = 0
                    if want < 0 or want >= count:
                        want = 0
                    var ctx = DeviceContext(device_id=want)
                    self.name = ctx.name()
                    self.device = want
                    self.ctx = ctx^
            except:
                self.ctx = None

    def available(self) -> Bool:
        return Bool(self.ctx)

    def render[f: PixelFn](self, width: Int, height: Int, p: Params) raises -> Rendered:
        """Runs f for every pixel on the GPU; returns the pixels and how long it took."""
        if not self.ctx:
            raise Error("no GPU found")
        ref ctx = self.ctx.value()
        var buf = ctx.enqueue_create_buffer[DType.uint32](width * height)
        ctx.synchronize()
        var t0 = now_ns()
        ctx.enqueue_function[_pixels_kernel[f]](
            buf.unsafe_ptr(), Int32(width), Int32(height), p,
            grid_dim=(ceildiv(width, 16), ceildiv(height, 16)), block_dim=(16, 16),
        )
        ctx.synchronize()
        var ms = Float64(now_ns() - t0) / 1e6
        var out = List[UInt32](capacity=width * height)
        with buf.map_to_host() as host:
            for i in range(width * height):
                out.append(host[i])
        return Rendered(out^, ms)


def render_on_cpu[f: PixelFn](width: Int, height: Int, p: Params) -> Rendered:
    """The same, one pixel at a time on the CPU (for checking and comparing)."""
    var t0 = now_ns()
    var out = List[UInt32](capacity=width * height)
    for y in range(height):
        for x in range(width):
            out.append(f(x, y, width, height, p))
    return Rendered(out^, Float64(now_ns() - t0) / 1e6)


def gpu_present() -> Bool:
    """Whether this machine has a GPU mojoui can use (cheap: doesn't start it)."""
    comptime if GPU_BUILD:
        try:
            return DeviceContext.number_of_devices() > 0
        except:
            return False
    return False


# ---------- point clouds: millions of points → a density picture ----------
#
#   def place(p: Point, w: Int, h: Int, k: Knobs) -> Int: ...   # pixel index, or OUTSIDE / FILTERED
#   def colour(count: UInt32, k: Knobs) -> UInt32: ...          # a pixel's colour from its count
#   var cloud = PointCloud(x^, y^, a^, b^)                       # columns; uploaded to the GPU once
#   var hits = cloud.bin[place](surface.width, surface.height, k)
#   cloud.shade[colour](surface, k)
#
# Both functions are plain Mojo. On a machine with a supported GPU they run as GPU
# kernels (one thread per point, then one per pixel); otherwise the same functions
# run on the CPU. The data stays on the GPU between frames.

from std.atomic import Atomic, Ordering
from max.gpu import grid_dim, block_dim, thread_idx, barrier
from max.gpu.memory import AddressSpace
from std.memory import stack_allocation
from max.gpu.host import DeviceBuffer
from mojoui.canvas import Surface

comptime Point = SIMD[DType.float32, 4]  # one point's four columns (x, y, a, b)
comptime Knobs = SIMD[DType.float32, 8]  # eight numbers the app's functions can use
comptime OUTSIDE = -1  # place(): matches, but falls outside the picture
comptime FILTERED = -2  # place(): doesn't match
comptime PlaceFn = def(Point, Int, Int, Knobs) thin -> Int
comptime ColourFn = def(UInt32, Knobs) thin -> UInt32


def _bin_kernel[f: PlaceFn](
    pts: UnsafePointer[Float32, MutAnyOrigin], n: Int32, counts: UnsafePointer[UInt32, MutAnyOrigin],
    w32: Int32, h32: Int32, k: Knobs,
):
    # Grid-stride loop: each thread takes many points, then adds its totals once.
    var w = Int(w32)
    var h = Int(h32)
    var stride = Int(grid_dim.x) * Int(block_dim.x)
    var matched = UInt32(0)
    var shown = UInt32(0)
    var i = Int(global_idx.x)
    while i < Int(n):
        var p = pts.unsafe_offset(4 * i).unsafe_load[width=4]()
        var at = f(p, w, h, k)
        if at >= OUTSIDE:
            matched += 1
        if at >= 0:
            shown += 1
            _ = Atomic.fetch_add[ordering=Ordering.RELAXED](counts.unsafe_offset(at), UInt32(1))
        i += stride
    if matched > 0:
        _ = Atomic.fetch_add[ordering=Ordering.RELAXED](counts.unsafe_offset(w * h), matched)
    if shown > 0:
        _ = Atomic.fetch_add[ordering=Ordering.RELAXED](counts.unsafe_offset(w * h + 1), shown)


def _shade_kernel[g: ColourFn](
    counts: UnsafePointer[UInt32, MutAnyOrigin], dst: UnsafePointer[UInt32, MutAnyOrigin], total: Int32, k: Knobs,
):
    var i = Int(global_idx.x)
    if i < Int(total):
        dst.unsafe_offset(i)[] = g(counts.unsafe_offset(i)[], k)


comptime StepFn = def(Point, Knobs) thin -> Point  # a point's next state (a simulation step)
comptime TintFn = def(Point, Knobs) thin -> SIMD[DType.float32, 4]  # the light a point adds: r, g, b in 0–1
comptime TRIAL_FRAMES = 6  # PointCloud.decide_blend: frames each way (compute first, then blending), of which the
comptime TRIAL_SKIP = 3  # first TRIAL_SKIP are warm-up (1 after the first measurement: the shaders are built by then)
comptime RECHECK = 120
comptime GLOW_ONE = Float32(1024)  # splat(): fixed point for added light (whole numbers, so GPU and CPU agree)


def _step_kernel[f: StepFn](pts: UnsafePointer[Float32, MutAnyOrigin], n: Int32, k: Knobs):
    var i = Int(global_idx.x)
    if i < Int(n):
        var at = pts.unsafe_offset(4 * i)
        at.unsafe_store[width=4](f(at.unsafe_load[width=4](), k))


def _glow(t: SIMD[DType.float32, 4]) -> SIMD[DType.uint32, 4]:
    return (min(max(t, SIMD[DType.float32, 4](0)), SIMD[DType.float32, 4](1)) * GLOW_ONE).cast[DType.uint32]()


def _splat_kernel[f: PlaceFn, g: TintFn](
    pts: UnsafePointer[Float32, MutAnyOrigin], n: Int32, light: UnsafePointer[UInt32, MutAnyOrigin],
    w32: Int32, h32: Int32, k: Knobs,
):
    var i = Int(global_idx.x)
    if i < Int(n):
        var p = pts.unsafe_offset(4 * i).unsafe_load[width=4]()
        var at = f(p, Int(w32), Int(h32), k)
        if at >= 0:
            # Saturation early-out: a channel's sum only grows and the picture clamps it at GLOW_ONE, so once it is
            # there more light changes nothing: skip that channel's atomic (where points pile up, most of them).
            # (A load, not fetch_add's old value: the tint is the app's, so no channel is known to fill last.)
            comptime one = UInt32(Int(GLOW_ONE))
            var add = _glow(g(p, k))
            var px = light.unsafe_offset(3 * at)
            comptime for c in range(3):
                if add[c] > 0 and Atomic.load[ordering=Ordering.RELAXED](px + c) < one:
                    _ = Atomic.fetch_add[ordering=Ordering.RELAXED](px + c, add[c])


def _light_rgba(r: UInt32, g: UInt32, b: UInt32) -> UInt32:
    """Added light → a pixel, clamped like additive blending (ONE, ONE) on black."""
    comptime one = UInt32(Int(GLOW_ONE))
    var ri = min(r, one) * 255 // one
    var gi = min(g, one) * 255 // one
    var bi = min(b, one) * 255 // one
    return ri | (gi << 8) | (bi << 16) | (UInt32(255) << 24)


def _splat2_kernel[f: PlaceFn, g: TintFn](
    pts: UnsafePointer[Float32, MutAnyOrigin], n: Int32, light: UnsafePointer[UInt32, MutAnyOrigin],
    w32: Int32, h32: Int32, k: Knobs,
):
    """The same light with two atomics a point instead of three (goal 36b M6c): four words a pixel, red and green
    one 64-bit word (red the low half), blue the third. The exactness bound is goal 36's: a channel is exact while its
    sum stays under 2^32, i.e. while fewer than about four million additions (2^32 / GLOW_ONE at full light) race
    past the saturation check on one pixel at once. Past that, a 32-bit channel used to wrap; here red would carry
    into green (D-741)."""
    var i = Int(global_idx.x)
    if i < Int(n):
        var p = pts.unsafe_offset(4 * i).unsafe_load[width=4]()
        var at = f(p, Int(w32), Int(h32), k)
        if at >= 0:
            comptime one = UInt32(Int(GLOW_ONE))
            var add = _glow(g(p, k))
            var px = light.unsafe_offset(4 * at)
            if add[0] > 0 or add[1] > 0:
                var rg = px.bitcast[UInt64]()
                var now = Atomic.load[ordering=Ordering.RELAXED](rg)
                var r_add = UInt64(add[0]) if UInt32(now & 0xFFFFFFFF) < one else UInt64(0)
                var g_add = UInt64(add[1]) if UInt32(now >> 32) < one else UInt64(0)
                var both = r_add | (g_add << 32)
                if both > 0:
                    _ = Atomic.fetch_add[ordering=Ordering.RELAXED](rg, both)
            if add[2] > 0 and Atomic.load[ordering=Ordering.RELAXED](px + 2) < one:
                _ = Atomic.fetch_add[ordering=Ordering.RELAXED](px + 2, add[2])


def _resolve_kernel(light: UnsafePointer[UInt32, MutAnyOrigin], dst: UnsafePointer[UInt32, MutAnyOrigin], total: Int32, words: Int32):
    """words: the light's words a pixel (3: one per channel; 4: the packed form, red and green first)."""
    var i = Int(global_idx.x)
    if i < Int(total):
        var w = Int(words)
        dst.unsafe_offset(i)[] = _light_rgba(light.unsafe_offset(w * i)[], light.unsafe_offset(w * i + 1)[], light.unsafe_offset(w * i + 2)[])


def _project_kernel[f: PlaceFn, g: TintFn](
    pts: UnsafePointer[Float32, MutAnyOrigin], n: Int32, verts: UnsafePointer[UInt32, MutAnyOrigin],
    w32: Int32, h32: Int32, k: Knobs, pairs: Int32,
):
    """One vertex a point for the GPU's blending (mojoui.present): its pixel (f; -1: none) and its light (g, in the
    splat's 1024ths, exact in float16), VERTEX_BYTES = 12: Int32, then r, g, b, a as float16."""
    var i = Int(global_idx.x)
    if i < Int(n):
        var p = pts.unsafe_offset(4 * i).unsafe_load[width=4]()
        var at = f(p, Int(w32), Int(h32), k)
        if pairs != 0 and at >= 0:  # lines: a segment with an end off the picture is left out (both ends)
            var j = i ^ 1
            if j >= Int(n) or f(pts.unsafe_offset(4 * j).unsafe_load[width=4](), Int(w32), Int(h32), k) < 0:
                at = -1
        var v = verts.unsafe_offset(3 * i)
        v[] = UInt32(at) if at >= 0 else UInt32(0xFFFFFFFF)
        var c = (_glow(g(p, k)).cast[DType.float32]() * Float32(1.0 / 1024.0)).cast[DType.float16]()
        var bits = bitcast[DType.uint32, 2](c)
        v.unsafe_offset(1)[] = bits[0]
        v.unsafe_offset(2)[] = bits[1]


struct PointCloud(Movable):
    """Up to four float32 columns of the same length, kept on the GPU (uploaded once) when there
    is one, and always on the CPU. Columns are what a dataframe hands over (e.g. MX frame)."""

    var gpu: Gpu
    var count: Int
    var host: List[Float32]  # four floats per point (x, y, a, b), the layout the GPU reads fastest
    var device: Optional[DeviceBuffer[DType.float32]]
    var counts: Optional[DeviceBuffer[DType.uint32]]  # w*h counts + matched + shown
    var image: Optional[DeviceBuffer[DType.uint32]]
    var host_counts: List[UInt32]
    var capacity: Int  # pixels the GPU buffers can hold
    var w: Int
    var h: Int
    var matched: Int  # points that matched in the last bin()
    var shown: Int  # of those, points inside the picture
    var uploads: Int
    var milliseconds: Float64  # last bin() + shade(), including the copy to the screen's memory
    var light: Optional[DeviceBuffer[DType.uint32]]  # splat(): added light, three channels per pixel, then the picture
    var splat_ms: Float64  # splat(timed=True): the GPU's part (clear, splat, resolve), then the copy to the CPU
    var readback_ms: Float64
    var host_light: List[UInt32]
    var light_capacity: Int
    var read_back: Int  # pictures copied from the GPU into a surface's CPU memory (bin/shade, splat)
    var handed: Int  # pictures left on the GPU for the host to show (surface.gpu_ok, goal 36b): no copy
    var blended: Int  # of those, drawn by the GPU's fixed-function blending (surface.gpu_painter)
    var three_atomics: Bool  # MOJOUI_SPLAT_ATOMICS=3: goal 36's splat (one atomic per channel), to compare
    # Additive points with a GPU painter on offer: blending or the compute splat, whichever is faster here (measured on
    # the first frames, D-739); MOJOUI_BLEND=1 always blends, 0 never
    var blend_pref: Int  # 0: measure, 1: always, 2: never
    var blend_choice: Int  # 0: measuring now, 1: blending, 2: compute splat (the start: points tend to pile up, and
    # blending can't skip saturated pixels; a first decision made on the first frames chose wrongly, D-739)
    var trial_ns: List[Int]  # TRIAL_FRAMES compute, then up to TRIAL_FRAMES blending (stopped early when it's clearly slower)
    var trials: Int  # measurements so far
    var since_trial: Int  # frames since the last decision: the work changes (points pile up, so the splat's saturation
    var interval: Int  # skip pays more), so both are measured again after `interval` frames: 60, doubling while the
    var told: Int  # choice holds, back to 60 when it flips (told: the choice last printed)

    def __init__(out self, x: List[Float32], y: List[Float32], a: List[Float32], b: List[Float32], use_gpu: Bool = True):
        self.gpu = Gpu(use_gpu)
        self.count = min(min(len(x), len(y)), min(len(a), len(b)))
        self.host = List[Float32](length=4 * self.count, fill=0)
        for i in range(self.count):
            self.host[4 * i] = x[i]
            self.host[4 * i + 1] = y[i]
            self.host[4 * i + 2] = a[i]
            self.host[4 * i + 3] = b[i]
        self.device = None
        self.counts = None
        self.image = None
        self.host_counts = List[UInt32]()
        self.capacity = 0
        self.w = 0
        self.h = 0
        self.matched = 0
        self.shown = 0
        self.uploads = 0
        self.milliseconds = 0
        self.light = None
        self.host_light = List[UInt32]()
        self.light_capacity = 0
        self.splat_ms = 0
        self.readback_ms = 0
        self.read_back = 0
        self.handed = 0
        self.blended = 0
        self.three_atomics = False
        self.blend_pref = 0
        comptime if GPU_BUILD:  # (Apple and Android builds have neither path, and no getenv in their stubs)
            self.three_atomics = getenv("MOJOUI_SPLAT_ATOMICS") == "3"
            var bp = getenv("MOJOUI_BLEND")
            self.blend_pref = 1 if bp == "1" else (2 if bp == "0" else 0)
        self.blend_choice = 2  # (the compute splat first; blending is measured against it after RECHECK frames)
        self.trial_ns = List[Int]()
        self.since_trial = 0
        self.told = 0
        self.trials = 0
        self.interval = RECHECK
        self.upload()

    def __init__(out self, var points: List[Float32], use_gpu: Bool = True):
        """Points already laid out four floats each (x, y, a, b), e.g. a simulation's (x, y, vx, vy): no copy."""
        self.gpu = Gpu(use_gpu)
        self.count = len(points) // 4
        self.host = points^
        self.device = None
        self.counts = None
        self.image = None
        self.host_counts = List[UInt32]()
        self.capacity = 0
        self.w = 0
        self.h = 0
        self.matched = 0
        self.shown = 0
        self.uploads = 0
        self.milliseconds = 0
        self.light = None
        self.host_light = List[UInt32]()
        self.light_capacity = 0
        self.splat_ms = 0
        self.readback_ms = 0
        self.read_back = 0
        self.handed = 0
        self.blended = 0
        self.three_atomics = False
        self.blend_pref = 0
        comptime if GPU_BUILD:  # (Apple and Android builds have neither path, and no getenv in their stubs)
            self.three_atomics = getenv("MOJOUI_SPLAT_ATOMICS") == "3"
            var bp = getenv("MOJOUI_BLEND")
            self.blend_pref = 1 if bp == "1" else (2 if bp == "0" else 0)
        self.blend_choice = 2  # (the compute splat first; blending is measured against it after RECHECK frames)
        self.trial_ns = List[Int]()
        self.since_trial = 0
        self.told = 0
        self.trials = 0
        self.interval = RECHECK
        self.upload()

    def upload(mut self):
        """Copies the points to the GPU (once, from __init__), when there is one."""
        comptime if GPU_BUILD:
            if self.gpu.available() and self.count > 0:
                try:
                    ref ctx = self.gpu.ctx.value()
                    var buf = ctx.enqueue_create_buffer[DType.float32](4 * self.count)
                    ctx.enqueue_copy(dst_buf=buf, src_ptr=self.host.unsafe_ptr())
                    ctx.synchronize()
                    self.device = buf^
                    self.uploads += 1
                except e:
                    print("mojoui.gpu: couldn't upload the points (" + String(e) + "); using the CPU")
                    self.device = None

    def on_gpu(self) -> Bool:
        return Bool(self.device)

    def give_up_gpu(mut self, why: String):
        """A GPU call failed: say so once, and use the CPU from now on (device_name() says CPU)."""
        comptime if GPU_BUILD:  # (other builds never had GPU buffers to drop)
            print("mojoui.gpu: GPU failed (" + why + "); using the CPU from now on")
            self.device = None
            self.counts = None
            self.image = None
            self.capacity = 0
            self.light = None
            self.light_capacity = 0

    def device_name(self) -> String:
        return self.gpu.name if self.on_gpu() else String("CPU")

    def bin[f: PlaceFn](mut self, w: Int, h: Int, k: Knobs) -> Int:
        """Counts the points landing on each of w × h pixels; returns how many matched."""
        var t0 = now_ns()
        self.w = w
        self.h = h
        comptime if GPU_BUILD:
            if self.on_gpu():
                try:
                    ref ctx = self.gpu.ctx.value()
                    if self.capacity < w * h:  # grow both buffers together; smaller pictures reuse them
                        var counts = ctx.enqueue_create_buffer[DType.uint32](w * h + 2)
                        var image = ctx.enqueue_create_buffer[DType.uint32](w * h)
                        self.counts = counts^
                        self.image = image^
                        self.capacity = w * h
                    var counts = self.counts.value().create_sub_buffer[DType.uint32](0, w * h + 2)
                    ctx.enqueue_memset(counts, 0)
                    var threads = 256
                    var blocks = min(ceildiv(self.count, threads), 4096)  # grid-stride: each thread takes many points
                    ctx.enqueue_function[_bin_kernel[f]](
                        self.device.value().unsafe_ptr(), Int32(self.count), counts.unsafe_ptr(), Int32(w), Int32(h), k,
                        grid_dim=blocks, block_dim=threads,
                    )
                    var totals = List[UInt32](length=2, fill=0)
                    ctx.enqueue_copy(dst_ptr=totals.unsafe_ptr(), src_buf=counts.create_sub_buffer[DType.uint32](w * h, 2))
                    ctx.synchronize()
                    self.matched = Int(totals[0])
                    self.shown = Int(totals[1])
                    self.milliseconds = Float64(now_ns() - t0) / 1e6
                    return self.matched
                except e:
                    self.give_up_gpu(String(e))  # the CPU from now on (below)
        if len(self.host_counts) != w * h:
            self.host_counts = List[UInt32](length=w * h, fill=0)
        else:
            for i in range(w * h):
                self.host_counts[i] = 0
        var matched = 0
        var shown = 0
        var pts = self.host.unsafe_ptr()
        for i in range(self.count):
            var p = pts.unsafe_offset(4 * i).unsafe_load[width=4]()
            var at = f(p, w, h, k)
            if at >= OUTSIDE:
                matched += 1
            if at >= 0:
                shown += 1
                self.host_counts[at] += 1
        self.matched = matched
        self.shown = shown
        self.milliseconds = Float64(now_ns() - t0) / 1e6
        return matched

    def shade[g: ColourFn](mut self, mut surface: Surface, k: Knobs):
        """Colours the surface from the last bin() (which must have used its width and height)."""
        var t0 = now_ns()
        var total = surface.width * surface.height
        if surface.width != self.w or surface.height != self.h:
            surface.fill(0)
            return
        comptime if GPU_BUILD:
            if self.on_gpu() and self.capacity >= total:
                try:
                    ref ctx = self.gpu.ctx.value()
                    var image = self.image.value().create_sub_buffer[DType.uint32](0, total)
                    ctx.enqueue_function[_shade_kernel[g]](
                        self.counts.value().unsafe_ptr(), image.unsafe_ptr(), Int32(total), k,
                        grid_dim=ceildiv(total, 256), block_dim=256,
                    )
                    surface.gpu_drawn = True
                    if surface.gpu_ok:  # the host shows it from GPU memory (mojoui.present): no copy, no wait (D-745)
                        surface.gpu_address = Int(image.unsafe_ptr())
                        surface.gpu_device = self.gpu.device
                        self.handed += 1
                        self.milliseconds += Float64(now_ns() - t0) / 1e6
                        return
                    var dst = UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=surface.address)
                    ctx.enqueue_copy(dst_ptr=dst, src_buf=image)
                    ctx.synchronize()
                    self.read_back += 1
                    self.milliseconds += Float64(now_ns() - t0) / 1e6
                    return
                except e:
                    self.give_up_gpu(String(e))
                    surface.fill(0)  # this frame's counts were on the GPU; the next frame bins on the CPU
                    return
        var p = surface.pixels()
        for i in range(total):
            p.unsafe_offset(i)[] = g(self.host_counts[i] if i < len(self.host_counts) else 0, k)
        self.milliseconds += Float64(now_ns() - t0) / 1e6


    # ---------- simulations: points that move ----------
    #
    #   def advance(p: Point, k: Knobs) -> Point: ...          # p = (x, y, vx, vy) → the next state
    #   def tint(p: Point, k: Knobs) -> SIMD[DType.float32, 4]: ...   # the light it adds (r, g, b, 0–1)
    #   cloud.step[advance](k)                                  # every point, in place (on the GPU when there is one)
    #   cloud.splat[place, tint](surface, k)                    # each point adds its light to one pixel (additive)
    #   var xyab = cloud.points()                               # the current points, back on the CPU

    def step[f: StepFn](mut self, k: Knobs, timed: Bool = False):
        """Replaces every point with f(point, k), in place. On the GPU it is queued: the next splat(), download() or
        points() waits for it (one wait a frame). timed=True waits here and sets milliseconds (the CPU always does)."""
        var t0 = now_ns()
        comptime if GPU_BUILD:
            if self.on_gpu():
                try:
                    ref ctx = self.gpu.ctx.value()
                    ctx.enqueue_function[_step_kernel[f]](
                        self.device.value().unsafe_ptr(), Int32(self.count), k,
                        grid_dim=ceildiv(self.count, 256), block_dim=256,
                    )
                    if timed:
                        ctx.synchronize()
                        self.milliseconds = Float64(now_ns() - t0) / 1e6
                    return
                except e:
                    self.download()  # (the last good points) then the CPU from now on
                    self.give_up_gpu(String(e))
        var pts = self.host.unsafe_ptr()
        for i in range(self.count):
            var at = pts.unsafe_offset(4 * i)
            at.unsafe_store[width=4](f(at.unsafe_load[width=4](), k))
        self.milliseconds = Float64(now_ns() - t0) / 1e6

    def download(mut self):
        """Copies the GPU's points back into the CPU's copy (after step(), the GPU's are the current ones)."""
        comptime if GPU_BUILD:
            if self.on_gpu():
                try:
                    ref ctx = self.gpu.ctx.value()
                    ctx.enqueue_copy(dst_ptr=self.host.unsafe_ptr(), src_buf=self.device.value())
                    ctx.synchronize()
                except e:
                    print("mojoui.gpu: couldn't read the points back (" + String(e) + ")")

    def points(mut self) -> List[Float32]:
        """The current points, four floats each (a copy, read back from the GPU when they live there)."""
        self.download()
        return self.host.copy()

    def blend_points(mut self, surface: Surface) -> Bool:
        """Whether this frame's additive points may go to the GPU painter (offered, same GPU, not ruled out)."""
        if surface.gpu_painter == 0 or self.blend_pref == 2:
            return False
        var pp = Pointer[Presenter, MutUntrackedOrigin](unsafe_from_address=surface.gpu_painter)
        if not pp[].blend_ok or pp[].device != self.gpu.device:
            return False
        if self.blend_pref == 1:
            self.blend_choice = 1
        elif self.blend_choice != 0:
            self.since_trial += 1
            if self.since_trial >= self.interval:
                self.blend_choice = 0  # (measure both again)
                self.trial_ns = List[Int]()
        return True

    def decide_blend(mut self):
        """Measures the compute splat for TRIAL_FRAMES frames, then blending for as many (in blocks: switching between GL
        and CUDA work every frame costs both); the first TRIAL_SKIP of each block are warm-up (1 after the first time).
        Blending stops early once a frame of it costs half again the splat's median. Keeps the faster by the median
        whole draw, the GPU's part included (blending waits for GL to finish while it's being timed)."""
        var skip = TRIAL_SKIP if self.trials == 0 else 1
        var done = len(self.trial_ns) - TRIAL_FRAMES  # blending frames measured
        if done <= skip:
            return
        var comp = List[Int]()
        for i in range(skip, TRIAL_FRAMES):
            comp.append(self.trial_ns[i])
        sort(comp)
        var c = Float64(comp[len(comp) // 2]) / 1e6
        var last = Float64(self.trial_ns[len(self.trial_ns) - 1]) / 1e6
        if done < TRIAL_FRAMES and last < c * 1.5:
            return
        var blend = List[Int]()
        for i in range(TRIAL_FRAMES + skip, len(self.trial_ns)):
            blend.append(self.trial_ns[i])
        sort(blend)
        var b = Float64(blend[len(blend) // 2]) / 1e6
        self.trials += 1
        var choice = 1 if b < c else 2
        if self.told == 1 and c > b * 0.9:  # (a switch has to win by a tenth: no flapping when they're close)
            choice = 1
        elif self.told == 2 and b > c * 0.9:
            choice = 2
        self.interval = min(self.interval * 2, 64 * RECHECK) if choice == self.told else RECHECK
        self.blend_choice = choice
        self.since_trial = 0
        if self.told == self.blend_choice:
            return
        self.told = self.blend_choice
        print("mojoui: additive points (" + String(self.count) + "): GPU blending " + String(Float64(Int(b * 1000)) / 1000)
              + " ms, compute splat " + String(Float64(Int(c * 1000)) / 1000) + " ms → " + ("GPU blending" if b < c else "compute splat"), flush=True)

    def paint_on_gpu[f: PlaceFn, g: TintFn](mut self, mut surface: Surface, k: Knobs, lines: Bool, over: Bool, timed: Bool, finish: Bool = False) -> Bool:
        """The GPU's own blending, when the host offers it (surface.gpu_painter, mojoui.present): a kernel writes one
        vertex a point (place f, light g) into the painter's vertex buffer, and the painter blends them into one of its
        textures, which the host shows (surface.gpu_slot). False: not offered or it failed (the caller draws another
        way)."""
        comptime if GPU_BUILD:
            if surface.gpu_painter == 0 or not self.on_gpu():
                return False
            var pp = Pointer[Presenter, MutUntrackedOrigin](unsafe_from_address=surface.gpu_painter)
            if not pp[].blend_ok or pp[].device != self.gpu.device:
                return False
            var t0 = now_ns()
            var w = surface.width
            var h = surface.height
            var slot = pp[].acquire(w, h)
            if slot < 0:
                return False
            var verts = pp[].begin_vertices(self.count)
            if verts == 0:
                return False
            try:
                ref ctx = self.gpu.ctx.value()
                ctx.enqueue_function[_project_kernel[f, g]](
                    self.device.value().unsafe_ptr(), Int32(self.count), UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=verts),
                    Int32(w), Int32(h), k, Int32(1 if lines else 0), grid_dim=ceildiv(self.count, 256), block_dim=256,
                )
                ctx.synchronize()  # (GL must not start on vertices CUDA is still writing: the driver would stall, D-746)
            except e:
                _ = pp[].draw_vertices(slot, w, h, 0, lines, over)  # (unmaps the buffer)
                pp[].give_up_blend("the vertex kernel failed: " + String(e))
                return False
            var t1 = now_ns()
            if not pp[].draw_vertices(slot, w, h, self.count, lines, over, finish):
                return False
            surface.gpu_slot = slot
            surface.gpu_drawn = True
            self.handed += 1
            self.blended += 1
            if timed:
                self.splat_ms = Float64(t1 - t0) / 1e6
                self.readback_ms = 0
            self.milliseconds = Float64(now_ns() - t0) / 1e6
            return True
        return False

    def paint[f: PlaceFn, g: TintFn](mut self, mut surface: Surface, k: Knobs, lines: Bool = False, over: Bool = False):
        """Draws the points (lines=True: each pair 2i, 2i+1 is a segment) with light g at the pixels f picks, blended
        additively (over=False: light adds up, clamped at white) or "over" in point order (g's fourth number is the
        opacity), on black. On the GPU's fixed-function blending when the host offers it; else additive points use the
        compute splat (splat()), and lines or "over" are drawn on the CPU (the points read back first)."""
        if not lines and not over:
            self.splat[f, g](surface, k)
            return
        comptime if GPU_BUILD:
            if self.on_gpu() and self.paint_on_gpu[f, g](surface, k, lines, over, False):
                return
            if self.on_gpu():
                self.download()
        var w = surface.width
        var h = surface.height
        var acc = List[Float32](length=3 * w * h, fill=0)
        var pts = self.host.unsafe_ptr()
        var step = 2 if lines else 1
        var i = 0
        while i + step <= self.count:
            var p = pts.unsafe_offset(4 * i).unsafe_load[width=4]()
            var a = f(p, w, h, k)
            var c = _glow(g(p, k)).cast[DType.float32]() * Float32(1.0 / 1024.0)
            var spots = List[Int]()
            if not lines:
                if a >= 0:
                    spots.append(a)
            else:
                var q = pts.unsafe_offset(4 * (i + 1)).unsafe_load[width=4]()
                var b = f(q, w, h, k)
                if a >= 0 and b >= 0:  # (pixel centres; the end pixel left out, as GL's diamond rule does)
                    var x0 = a % w
                    var y0 = a // w
                    var dx = b % w - x0
                    var dy = b // w - y0
                    var steps = max(abs(dx), abs(dy))
                    for s in range(steps):
                        var x = x0 + Int(Float64(dx * s) / Float64(steps) + (0.5 if dx * s >= 0 else -0.5))
                        var y = y0 + Int(Float64(dy * s) / Float64(steps) + (0.5 if dy * s >= 0 else -0.5))
                        spots.append(y * w + x)
            for at in spots:
                comptime for ch in range(3):
                    if over:
                        acc[3 * at + ch] = acc[3 * at + ch] * (Float32(1) - c[3]) + c[ch] * c[3]
                    else:
                        acc[3 * at + ch] += c[ch]
            i += step
        var px = surface.pixels()
        for j in range(w * h):
            var r = UInt32(Int(min(acc[3 * j], Float32(1)) * 1024 + 0.5))
            var gg = UInt32(Int(min(acc[3 * j + 1], Float32(1)) * 1024 + 0.5))
            var b = UInt32(Int(min(acc[3 * j + 2], Float32(1)) * 1024 + 0.5))
            px.unsafe_offset(j)[] = _light_rgba(r, gg, b)

    def splat[f: PlaceFn, g: TintFn](mut self, mut surface: Surface, k: Knobs, timed: Bool = False):
        """Paints the surface black, then each point adds g(point)'s light to the pixel f(point) picks (OUTSIDE or
        FILTERED: none), clamped at white: additive blending. Light adds up as whole numbers, so the GPU and the CPU
        make the same picture. milliseconds: how long, including the copy into the surface (and any step() still
        queued); timed=True also splits it into splat_ms (GPU) and readback_ms (the copy), at the cost of a second wait.
        When the host can show a GPU picture (surface.gpu_ok), the picture stays on the GPU and the surface says where
        (surface.gpu_address): no copy to the CPU and no wait: the host's GPU→GPU copy is queued after these kernels
        (D-745), so the CPU goes on to the next frame while the GPU works."""
        var t0 = now_ns()
        var w = surface.width
        var h = surface.height
        var total = w * h
        comptime if GPU_BUILD:
            if self.on_gpu() and self.blend_points(surface):
                var trial = self.blend_choice == 0
                var at = len(self.trial_ns)
                if (not trial and self.blend_choice == 1) or (trial and at >= TRIAL_FRAMES):
                    if self.paint_on_gpu[f, g](surface, k, False, False, timed, trial):
                        if trial:
                            self.trial_ns.append(Int(now_ns() - t0))
                            self.decide_blend()
                        return
                    self.blend_choice = 2  # (it failed: the painter said why; the compute splat from now on)
            if self.on_gpu():
                try:
                    ref ctx = self.gpu.ctx.value()
                    if self.light_capacity < total:  # light (up to 4 words per pixel), then the picture (1 per pixel)
                        self.light = ctx.enqueue_create_buffer[DType.uint32](5 * total)
                        self.light_capacity = total
                    var words = 3 if self.three_atomics else 4
                    var light = self.light.value().create_sub_buffer[DType.uint32](0, words * total)
                    var image = self.light.value().create_sub_buffer[DType.uint32](4 * total, total)
                    ctx.enqueue_memset(light, 0)
                    if self.three_atomics:
                        ctx.enqueue_function[_splat_kernel[f, g]](
                            self.device.value().unsafe_ptr(), Int32(self.count), light.unsafe_ptr(), Int32(w), Int32(h), k,
                            grid_dim=ceildiv(self.count, 256), block_dim=256,
                        )
                    else:
                        ctx.enqueue_function[_splat2_kernel[f, g]](
                            self.device.value().unsafe_ptr(), Int32(self.count), light.unsafe_ptr(), Int32(w), Int32(h), k,
                            grid_dim=ceildiv(self.count, 256), block_dim=256,
                        )
                    ctx.enqueue_function[_resolve_kernel](
                        light.unsafe_ptr(), image.unsafe_ptr(), Int32(total), Int32(words), grid_dim=ceildiv(total, 256), block_dim=256,
                    )
                    surface.gpu_drawn = True
                    var t1 = t0
                    if timed:  # (measuring: wait for the kernels, so the copy to the CPU is timed on its own)
                        ctx.synchronize()
                        t1 = now_ns()
                        self.splat_ms = Float64(t1 - t0) / 1e6
                    if surface.gpu_ok:  # the host shows the picture from GPU memory (mojoui.present): no readback
                        if self.blend_choice == 0 and surface.gpu_painter != 0:  # (measuring against blending: whole work)
                            ctx.synchronize()
                            t1 = now_ns()
                        surface.gpu_address = Int(image.unsafe_ptr())
                        surface.gpu_device = self.gpu.device
                        self.handed += 1
                        if timed:
                            self.readback_ms = 0
                        self.milliseconds = Float64(t1 - t0) / 1e6
                        if self.blend_choice == 0 and surface.gpu_painter != 0 and len(self.trial_ns) < TRIAL_FRAMES:
                            self.trial_ns.append(Int(t1 - t0))
                        return
                    var dst = UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=surface.address)
                    ctx.enqueue_copy(dst_ptr=dst, src_buf=image)
                    ctx.synchronize()
                    self.read_back += 1
                    var t2 = now_ns()
                    if timed:
                        self.readback_ms = Float64(t2 - t1) / 1e6
                    self.milliseconds = Float64(t2 - t0) / 1e6
                    return
                except e:
                    self.download()
                    self.give_up_gpu(String(e))
        if len(self.host_light) != 3 * total:
            self.host_light = List[UInt32](length=3 * total, fill=0)
        else:
            for i in range(3 * total):
                self.host_light[i] = 0
        var pts = self.host.unsafe_ptr()
        for i in range(self.count):
            var p = pts.unsafe_offset(4 * i).unsafe_load[width=4]()
            var at = f(p, w, h, k)
            if at >= 0:
                var add = _glow(g(p, k))
                self.host_light[3 * at] += add[0]
                self.host_light[3 * at + 1] += add[1]
                self.host_light[3 * at + 2] += add[2]
        var px = surface.pixels()
        for i in range(total):
            px.unsafe_offset(i)[] = _light_rgba(self.host_light[3 * i], self.host_light[3 * i + 1], self.host_light[3 * i + 2])
        self.milliseconds = Float64(now_ns() - t0) / 1e6


# ---------- tables: millions of rows → exact group totals ----------
#
#   def by_region(r: Row, f: Filter) -> Int: ...     # the group a row adds to, or -1 (filtered out)
#   def revenue(r: Row, f: Filter) -> Int: ...       # what it adds (whole numbers, e.g. cents)
#   var t = Table(columns)                            # up to 8 int32 columns; uploaded to the GPU once
#   var totals = t.group_sum[by_region, revenue](5, filter)   # totals.sums[g], totals.counts[g]
#
# Sums are 64-bit integers, so GPU and CPU agree exactly (to the cent).

comptime Row = SIMD[DType.int32, 8]  # one row's columns
comptime Filter = SIMD[DType.int32, 16]  # sixteen numbers the app's functions can use
comptime GroupFn = def(Row, Filter) thin -> Int
comptime AmountFn = def(Row, Filter) thin -> Int


@fieldwise_init
struct GroupSums(Copyable, Movable):
    var sums: List[Int]
    var counts: List[Int]
    var milliseconds: Float64


comptime SHARED_GROUPS = 128  # up to this many groups are added up per block in shared memory first


def _group_kernel[g: GroupFn, a: AmountFn](
    rows: UnsafePointer[Int32, MutAnyOrigin], n: Int32, acc: UnsafePointer[UInt64, MutAnyOrigin], groups: Int32, f: Filter,
):
    # Each block adds into its own totals in shared memory (fast, little contention), then adds
    # those into the global totals once: few groups no longer means millions of atomics on one address.
    var local = stack_allocation[2 * SHARED_GROUPS, UInt64, address_space=AddressSpace.SHARED]()
    var shared = Int(groups) <= SHARED_GROUPS
    var t = Int(thread_idx.x)
    var k = t
    while k < 2 * SHARED_GROUPS:
        local[k] = 0
        k += Int(block_dim.x)
    barrier()
    var stride = Int(grid_dim.x) * Int(block_dim.x)
    var i = Int(global_idx.x)
    while i < Int(n):
        var r = rows.unsafe_offset(8 * i).unsafe_load[width=8]()
        var grp = g(r, f)
        if grp >= 0 and grp < Int(groups):
            if shared:
                _ = Atomic.fetch_add[ordering=Ordering.RELAXED](local + 2 * grp, UInt64(a(r, f)))
                _ = Atomic.fetch_add[ordering=Ordering.RELAXED](local + (2 * grp + 1), UInt64(1))
            else:
                _ = Atomic.fetch_add[ordering=Ordering.RELAXED](acc.unsafe_offset(2 * grp), UInt64(a(r, f)))
                _ = Atomic.fetch_add[ordering=Ordering.RELAXED](acc.unsafe_offset(2 * grp + 1), UInt64(1))
        i += stride
    barrier()
    if shared:
        k = t
        while k < 2 * Int(groups):
            if local[k] != 0:
                _ = Atomic.fetch_add[ordering=Ordering.RELAXED](acc.unsafe_offset(k), local[k])
            k += Int(block_dim.x)


struct Table(Movable):
    """Rows of up to eight int32 columns, kept on the GPU (uploaded once) when there is one."""

    var gpu: Gpu
    var count: Int
    var host: List[Int32]  # eight per row
    var device: Optional[DeviceBuffer[DType.int32]]
    var acc: Optional[DeviceBuffer[DType.uint64]]
    var acc_groups: Int
    var uploads: Int

    def __init__(out self, columns: List[List[Int32]], use_gpu: Bool = True):
        self.gpu = Gpu(use_gpu)
        self.count = len(columns[0]) if len(columns) > 0 else 0
        self.host = List[Int32](length=8 * self.count, fill=0)
        for c in range(min(len(columns), 8)):
            for i in range(self.count):
                self.host[8 * i + c] = columns[c][i]
        self.device = None
        self.acc = None
        self.acc_groups = 0
        self.uploads = 0
        comptime if GPU_BUILD:
            if self.gpu.available() and self.count > 0:
                try:
                    ref ctx = self.gpu.ctx.value()
                    var buf = ctx.enqueue_create_buffer[DType.int32](8 * self.count)
                    ctx.enqueue_copy(dst_buf=buf, src_ptr=self.host.unsafe_ptr())
                    ctx.synchronize()
                    self.device = buf^
                    self.uploads += 1
                except e:
                    print("mojoui.gpu: couldn't upload the table (" + String(e) + "); using the CPU")
                    self.device = None

    def on_gpu(self) -> Bool:
        return Bool(self.device)

    def device_name(self) -> String:
        return self.gpu.name if self.on_gpu() else String("CPU")

    def group_sum[g: GroupFn, a: AmountFn](mut self, groups: Int, f: Filter, use_gpu: Bool = True) -> GroupSums:
        """For each row, g() picks a group (or -1) and a() what it adds: per-group sums and row counts.
        use_gpu=False runs it on the CPU even when the table is on a GPU (to compare)."""
        var t0 = now_ns()
        var sums = List[Int](length=groups, fill=0)
        var counts = List[Int](length=groups, fill=0)
        comptime if GPU_BUILD:
            if self.on_gpu() and use_gpu:
                try:
                    ref ctx = self.gpu.ctx.value()
                    if self.acc_groups < groups:
                        self.acc = ctx.enqueue_create_buffer[DType.uint64](2 * groups)
                        self.acc_groups = groups
                    var acc = self.acc.value().create_sub_buffer[DType.uint64](0, 2 * groups)
                    ctx.enqueue_memset(acc, 0)
                    ctx.enqueue_function[_group_kernel[g, a]](
                        self.device.value().unsafe_ptr(), Int32(self.count), acc.unsafe_ptr(), Int32(groups), f,
                        grid_dim=min(ceildiv(self.count, 256), 4096), block_dim=256,
                    )
                    var out = List[UInt64](length=2 * groups, fill=0)
                    ctx.enqueue_copy(dst_ptr=out.unsafe_ptr(), src_buf=acc)
                    ctx.synchronize()
                    for k in range(groups):
                        sums[k] = Int(out[2 * k])
                        counts[k] = Int(out[2 * k + 1])
                    return GroupSums(sums^, counts^, Float64(now_ns() - t0) / 1e6)
                except e:
                    print("mojoui.gpu: group_sum failed (" + String(e) + "); using the CPU")
                    self.device = None
        var p = self.host.unsafe_ptr()
        for i in range(self.count):
            var r = p.unsafe_offset(8 * i).unsafe_load[width=8]()
            var grp = g(r, f)
            if grp >= 0 and grp < groups:
                sums[grp] += a(r, f)
                counts[grp] += 1
        return GroupSums(sums^, counts^, Float64(now_ns() - t0) / 1e6)
