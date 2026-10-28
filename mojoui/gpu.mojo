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

    def __init__(out self, use: Bool = True):
        """use=False: act as if there were no GPU (to compare with the CPU)."""
        self.ctx = None
        self.name = "no GPU found"
        if not use:
            return
        comptime if GPU_BUILD:  # (Apple builds: the CPU path; MAX's Apple GPU runtime isn't linked)
            try:
                if DeviceContext.number_of_devices() > 0:
                    var ctx = DeviceContext()
                    self.name = ctx.name()
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
            var add = _glow(g(p, k))
            _ = Atomic.fetch_add[ordering=Ordering.RELAXED](light.unsafe_offset(3 * at), add[0])
            _ = Atomic.fetch_add[ordering=Ordering.RELAXED](light.unsafe_offset(3 * at + 1), add[1])
            _ = Atomic.fetch_add[ordering=Ordering.RELAXED](light.unsafe_offset(3 * at + 2), add[2])


def _light_rgba(r: UInt32, g: UInt32, b: UInt32) -> UInt32:
    """Added light → a pixel, clamped like additive blending (ONE, ONE) on black."""
    comptime one = UInt32(Int(GLOW_ONE))
    var ri = min(r, one) * 255 // one
    var gi = min(g, one) * 255 // one
    var bi = min(b, one) * 255 // one
    return ri | (gi << 8) | (bi << 16) | (UInt32(255) << 24)


def _resolve_kernel(light: UnsafePointer[UInt32, MutAnyOrigin], dst: UnsafePointer[UInt32, MutAnyOrigin], total: Int32):
    var i = Int(global_idx.x)
    if i < Int(total):
        dst.unsafe_offset(i)[] = _light_rgba(light.unsafe_offset(3 * i)[], light.unsafe_offset(3 * i + 1)[], light.unsafe_offset(3 * i + 2)[])


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
    var host_light: List[UInt32]
    var light_capacity: Int

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
                    var dst = UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=surface.address)
                    ctx.enqueue_copy(dst_ptr=dst, src_buf=image)
                    ctx.synchronize()
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

    def step[f: StepFn](mut self, k: Knobs):
        """Replaces every point with f(point, k), in place; returns once it's done (milliseconds: how long)."""
        var t0 = now_ns()
        comptime if GPU_BUILD:
            if self.on_gpu():
                try:
                    ref ctx = self.gpu.ctx.value()
                    ctx.enqueue_function[_step_kernel[f]](
                        self.device.value().unsafe_ptr(), Int32(self.count), k,
                        grid_dim=ceildiv(self.count, 256), block_dim=256,
                    )
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

    def splat[f: PlaceFn, g: TintFn](mut self, mut surface: Surface, k: Knobs):
        """Paints the surface black, then each point adds g(point)'s light to the pixel f(point) picks (OUTSIDE or
        FILTERED: none), clamped at white: additive blending. Light adds up as whole numbers, so the GPU and the CPU
        make the same picture. milliseconds: how long, including the copy into the surface."""
        var t0 = now_ns()
        var w = surface.width
        var h = surface.height
        var total = w * h
        comptime if GPU_BUILD:
            if self.on_gpu():
                try:
                    ref ctx = self.gpu.ctx.value()
                    if self.light_capacity < total:  # light (3 per pixel), then the picture (1 per pixel)
                        self.light = ctx.enqueue_create_buffer[DType.uint32](4 * total)
                        self.light_capacity = total
                    var light = self.light.value().create_sub_buffer[DType.uint32](0, 3 * total)
                    var image = self.light.value().create_sub_buffer[DType.uint32](3 * total, total)
                    ctx.enqueue_memset(light, 0)
                    ctx.enqueue_function[_splat_kernel[f, g]](
                        self.device.value().unsafe_ptr(), Int32(self.count), light.unsafe_ptr(), Int32(w), Int32(h), k,
                        grid_dim=ceildiv(self.count, 256), block_dim=256,
                    )
                    ctx.enqueue_function[_resolve_kernel](
                        light.unsafe_ptr(), image.unsafe_ptr(), Int32(total), grid_dim=ceildiv(total, 256), block_dim=256,
                    )
                    var dst = UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=surface.address)
                    ctx.enqueue_copy(dst_ptr=dst, src_buf=image)
                    ctx.synchronize()
                    self.milliseconds = Float64(now_ns() - t0) / 1e6
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
