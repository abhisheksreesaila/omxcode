# Operations on an RGBA frame (a video frame, a photo): blur a rectangle (faces, plates), crop and scale (thumbnails),
# burn a caption in (a shipment ID), fill or outline a rectangle (a detection box). Pixels are UInt32s with R in the low
# byte, like Surface and Image. Each operation runs on the GPU when there is one (Linux) and on the CPU otherwise; both
# run the same integer arithmetic, so they give the same pixels.
#
#   var ops = ImageOps()                                   # once: owns the GPU context, its buffers and the font
#   var frame = Frame(1280, 720)                           # or Frame(w, h, pixels^)
#   var edits = Edits()                                    # everything to do to one frame, in order
#   edits.blur(100, 80, 120, 120, 12)                      # strong blur inside the rectangle only (3 box passes)
#   edits.outline_rect(90, 70, 140, 140, rgba(255, 60, 60), 3, 6)
#   ops.text(edits, 20, 20, "SHP-00417", 22, rgba(255, 255, 255), rgba(0, 0, 0, 170))   # caption on a pill
#   ops.apply(frame, edits)                                # one trip to the GPU for the edits that don't overlap
#   var thumb = ops.crop(frame, 100, 80, 120, 120, 64, 64, bilinear=True)
#
# Only the rectangles being edited travel to the GPU and back, not the whole frame: blur is clamped at its rectangle's
# edges, so everything outside stays exactly as it was and costs nothing.

from max.gpu import global_idx
from max.gpu.host import DeviceBuffer
from std.math import ceildiv
from mojoui.canvas import Surface, rgba
from mojoui.clock import now_ns
from mojoui.draw import rect
from mojoui.gpu import Gpu, GPU_BUILD
from mojoui.text import Font, MEDIUM

comptime BLUR = 0
comptime PATCH = 1  # coverage drawn on the CPU (text, rectangles), composited onto the frame by colour
comptime PASSES = 3  # three box blurs ≈ a gaussian


# ---------- the arithmetic both paths run (integers only, so GPU and CPU agree) ----------


def _over(d: UInt32, c: UInt32, cov: Int) -> UInt32:
    """Colour c (its own alpha times cov, 0–255) over the pixel d; d's alpha stays."""
    var a = (cov * Int((c >> 24) & 0xFF) + 127) // 255
    if a <= 0:
        return d
    var r = (Int(c & 0xFF) * a + Int(d & 0xFF) * (255 - a) + 127) // 255
    var g = (Int((c >> 8) & 0xFF) * a + Int((d >> 8) & 0xFF) * (255 - a) + 127) // 255
    var b = (Int((c >> 16) & 0xFF) * a + Int((d >> 16) & 0xFF) * (255 - a) + 127) // 255
    return UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | (d & 0xFF000000)


def _compose_px(d: UInt32, cov: UInt32, c1: UInt32, c2: UInt32) -> UInt32:
    """cov: low byte = c1's coverage (text, a rectangle), next byte = c2's (the pill behind the text); c2 goes first."""
    return _over(_over(d, c2, Int((cov >> 8) & 0xFF)), c1, Int(cov & 0xFF))


def _blur_px(src: UnsafePointer[UInt32, MutAnyOrigin], w: Int, h: Int, x: Int, y: Int, r: Int, horiz: Bool) -> UInt32:
    """The mean of the 2r+1 pixels along a row (or column), with the edge pixel repeated beyond the rectangle."""
    var sr = 0
    var sg = 0
    var sb = 0
    var sa = 0
    for k in range(-r, r + 1):
        var px = min(max(x + k, 0), w - 1) if horiz else x
        var py = y if horiz else min(max(y + k, 0), h - 1)
        var p = src.unsafe_offset(py * w + px)[]
        sr += Int(p & 0xFF)
        sg += Int((p >> 8) & 0xFF)
        sb += Int((p >> 16) & 0xFF)
        sa += Int((p >> 24) & 0xFF)
    var n = 2 * r + 1
    var h2 = n // 2
    return UInt32((sr + h2) // n) | (UInt32((sg + h2) // n) << 8) | (UInt32((sb + h2) // n) << 16) | (UInt32((sa + h2) // n) << 24)


def _scale_px(src: UnsafePointer[UInt32, MutAnyOrigin], sw: Int, sh: Int, ow: Int, oh: Int, x: Int, y: Int, bilinear: Bool) -> UInt32:
    """Output pixel (x, y) of a sw×sh picture scaled to ow×oh, sampled at pixel centres."""
    if not bilinear:
        var sx = min(sw - 1, ((2 * x + 1) * sw) // (2 * ow))
        var sy = min(sh - 1, ((2 * y + 1) * sh) // (2 * oh))
        return src.unsafe_offset(sy * sw + sx)[]
    var px = max(((2 * x + 1) * sw * 256) // (2 * ow) - 128, 0)  # source position in 1/256 pixels
    var py = max(((2 * y + 1) * sh * 256) // (2 * oh) - 128, 0)
    var x0 = min(px >> 8, sw - 1)
    var y0 = min(py >> 8, sh - 1)
    var x1 = min(x0 + 1, sw - 1)
    var y1 = min(y0 + 1, sh - 1)
    var fx = px & 255
    var fy = py & 255
    var a = src.unsafe_offset(y0 * sw + x0)[]
    var b = src.unsafe_offset(y0 * sw + x1)[]
    var c = src.unsafe_offset(y1 * sw + x0)[]
    var d = src.unsafe_offset(y1 * sw + x1)[]
    var out = UInt32(0)
    for ch in range(4):
        var s = UInt32(ch * 8)
        var v = (
            Int((a >> s) & 0xFF) * (256 - fx) * (256 - fy) + Int((b >> s) & 0xFF) * fx * (256 - fy)
            + Int((c >> s) & 0xFF) * (256 - fx) * fy + Int((d >> s) & 0xFF) * fx * fy + 32768
        ) >> 16
        out |= UInt32(v) << s
    return out


def _raw(p: Pointer[UInt32, _]) -> UnsafePointer[UInt32, MutAnyOrigin]:
    return UnsafePointer[UInt32, MutAnyOrigin](unsafe_from_address=Int(p))


# ---------- GPU kernels: one thread per output pixel ----------


def _blur_kernel(src: UnsafePointer[UInt32, MutAnyOrigin], dst: UnsafePointer[UInt32, MutAnyOrigin], w: Int32, h: Int32, r: Int32, horiz: Int32):
    var x = Int(global_idx.x)
    var y = Int(global_idx.y)
    if x < Int(w) and y < Int(h):
        dst.unsafe_offset(y * Int(w) + x)[] = _blur_px(src, Int(w), Int(h), x, y, Int(r), horiz != 0)


def _compose_kernel(dst: UnsafePointer[UInt32, MutAnyOrigin], cov: UnsafePointer[UInt32, MutAnyOrigin], w: Int32, h: Int32, c1: UInt32, c2: UInt32):
    var x = Int(global_idx.x)
    var y = Int(global_idx.y)
    if x < Int(w) and y < Int(h):
        var i = y * Int(w) + x
        dst.unsafe_offset(i)[] = _compose_px(dst.unsafe_offset(i)[], cov.unsafe_offset(i)[], c1, c2)


def _scale_kernel(src: UnsafePointer[UInt32, MutAnyOrigin], dst: UnsafePointer[UInt32, MutAnyOrigin], sw: Int32, sh: Int32, ow: Int32, oh: Int32, bilinear: Int32):
    var x = Int(global_idx.x)
    var y = Int(global_idx.y)
    if x < Int(ow) and y < Int(oh):
        dst.unsafe_offset(y * Int(ow) + x)[] = _scale_px(src, Int(sw), Int(sh), Int(ow), Int(oh), x, y, bilinear != 0)


# ---------- frames and edits ----------


struct Frame(Copyable, Movable):
    """An RGBA picture: `pixels` row by row, width × height of them."""

    var width: Int
    var height: Int
    var pixels: List[UInt32]

    def __init__(out self, width: Int, height: Int, fill: UInt32 = 0):
        self.width = width
        self.height = height
        self.pixels = List[UInt32](length=width * height, fill=fill)

    def __init__(out self, width: Int, height: Int, var pixels: List[UInt32]):
        self.width = width
        self.height = height
        self.pixels = pixels^


@fieldwise_init
struct Edit(Copyable, Movable):
    var kind: Int
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var radius: Int  # BLUR: the box radius in pixels
    var c1: UInt32  # PATCH: the colour for the coverage's low byte (text, a rectangle)
    var c2: UInt32  # PATCH: the colour for its second byte (the pill behind text)
    var offset: Int  # PATCH: where its w×h coverage starts in Edits.cov


struct Edits(Movable):
    """What to do to one frame, in order. Build it, then `ImageOps.apply(frame, edits)`."""

    var list: List[Edit]
    var cov: List[UInt32]

    def __init__(out self):
        self.list = List[Edit]()
        self.cov = List[UInt32]()

    def blur(mut self, x: Int, y: Int, w: Int, h: Int, radius: Int):
        """A strong blur inside the rectangle (radius ≈ 1/10 of its size is unrecognisable); it never reads or writes outside."""
        self.list.append(Edit(BLUR, x, y, w, h, max(radius, 1), 0, 0, 0))

    def _patch(mut self, x: Int, y: Int, w: Int, h: Int, var cov: List[UInt32], c1: UInt32, c2: UInt32):
        self.list.append(Edit(PATCH, x, y, w, h, 0, c1, c2, len(self.cov)))
        self.cov.extend(cov^)

    def fill_rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64, colour: UInt32, radius: Float64 = 0):
        """A rectangle in `colour` (its alpha is the opacity), anti-aliased, optionally rounded."""
        var ix = Int(x)
        var iy = Int(y)
        var pw = Int(w) + 3
        var ph = Int(h) + 3
        var cov = List[UInt32](length=pw * ph, fill=0xFF000000)
        var s = Surface(Int(cov.unsafe_ptr()), pw, ph, 1.0)
        rect(s, x - Float64(ix), y - Float64(iy), w, h, rgba(255, 255, 255), radius)
        self._patch(ix, iy, pw, ph, _low_byte(cov^), colour, 0)

    def outline_rect(mut self, x: Float64, y: Float64, w: Float64, h: Float64, colour: UInt32, thickness: Float64 = 2, radius: Float64 = 0):
        """A rectangle's outline (a detection box): `thickness` pixels inside the edge."""
        var ix = Int(x)
        var iy = Int(y)
        var pw = Int(w) + 3
        var ph = Int(h) + 3
        var cov = List[UInt32](length=pw * ph, fill=0xFF000000)
        var s = Surface(Int(cov.unsafe_ptr()), pw, ph, 1.0)
        var fx = x - Float64(ix)
        var fy = y - Float64(iy)
        rect(s, fx, fy, w, h, rgba(255, 255, 255), radius)
        rect(s, fx + thickness, fy + thickness, w - 2 * thickness, h - 2 * thickness, rgba(0, 0, 0), max(radius - thickness, 0))
        self._patch(ix, iy, pw, ph, _low_byte(cov^), colour, 0)


def _low_byte(var pixels: List[UInt32]) -> List[UInt32]:
    for i in range(len(pixels)):
        pixels[i] = pixels[i] & 0xFF
    return pixels^


def _intersects(a: Edit, ax: Int, ay: Int, aw: Int, ah: Int, bx: Int, by: Int, bw: Int, bh: Int) -> Bool:
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah


struct ImageOps(Movable):
    """Runs Edits on frames. Keep one: it holds the GPU context, device buffers that grow as needed, and the font."""

    var gpu: Gpu
    var font: Font
    var a: Optional[DeviceBuffer[DType.uint32]]  # the rectangles being edited, one after another
    var b: Optional[DeviceBuffer[DType.uint32]]  # the blur's other half; and the patches' coverage
    var capacity: Int
    var stage: List[UInt32]  # the same rectangles on the host
    var cov: List[UInt32]
    var scratch: List[UInt32]
    var millis: Float64  # the last apply(): time taken, upload and download included, in ms

    def __init__(out self, use_gpu: Bool = True):
        self.gpu = Gpu(use_gpu)
        self.font = Font()
        self.a = None
        self.b = None
        self.capacity = 0
        self.stage = List[UInt32]()
        self.cov = List[UInt32]()
        self.scratch = List[UInt32]()
        self.millis = 0

    def on_gpu(self) -> Bool:
        return self.gpu.available()

    def _ensure(mut self, n: Int) raises:
        comptime if GPU_BUILD:
            if n > self.capacity and self.gpu.ctx:
                ref ctx = self.gpu.ctx.value()
                var size = max(n, 2 * self.capacity)
                self.a = ctx.enqueue_create_buffer[DType.uint32](size)
                self.b = ctx.enqueue_create_buffer[DType.uint32](size)
                self.capacity = size

    # ---- convenience for one edit ----

    def blur_box(mut self, mut frame: Frame, x: Int, y: Int, w: Int, h: Int, radius: Int) raises:
        var e = Edits()
        e.blur(x, y, w, h, radius)
        self.apply(frame, e)

    def draw_text(mut self, mut frame: Frame, x: Int, y: Int, text: String, size: Float64, colour: UInt32, pill: UInt32 = 0) raises:
        var e = Edits()
        self.text(e, x, y, text, size, colour, pill)
        self.apply(frame, e)

    # ---- text ----

    def text(mut self, mut edits: Edits, x: Int, y: Int, text: String, size: Float64, colour: UInt32, pill: UInt32 = 0):
        """Adds a caption whose box has its top-left at (x, y), in Inter Medium; `pill`, if it has any alpha, is drawn
        behind it as a rounded box. The glyphs are the framework's own (mojoui.text), anti-aliased."""
        var pad = Int(size * 0.35 + 0.5)
        var ascent = self.font.ascent(size)
        var tw = Int(self.font.measure(text, size, MEDIUM) + 1)
        var pw = tw + 2 * pad
        var ph = Int(ascent + size * 0.3 + 1) + 2 * pad
        var text_cov = List[UInt32](length=pw * ph, fill=0xFF000000)
        var s = Surface(Int(text_cov.unsafe_ptr()), pw, ph, 1.0)
        self.font.draw(s, text, Float64(pad), Float64(pad) + ascent, size, rgba(255, 255, 255), MEDIUM)
        if (pill >> 24) != 0:
            var pill_cov = List[UInt32](length=pw * ph, fill=0xFF000000)
            var p = Surface(Int(pill_cov.unsafe_ptr()), pw, ph, 1.0)
            rect(p, 0, 0, Float64(pw), Float64(ph), rgba(255, 255, 255), Float64(ph) / 2)
            for i in range(pw * ph):
                text_cov[i] = (text_cov[i] & 0xFF) | ((pill_cov[i] & 0xFF) << 8)
        else:
            for i in range(pw * ph):
                text_cov[i] = text_cov[i] & 0xFF
        edits._patch(x, y, pw, ph, text_cov^, colour, pill)

    # ---- running edits ----

    def apply(mut self, mut frame: Frame, edits: Edits) raises:
        """Does the edits in order. Edits that don't overlap share one trip to the GPU; an edit that overlaps an earlier
        one waits for it."""
        var t0 = Int(now_ns())
        var i = 0
        var n = len(edits.list)
        while i < n:
            var j = i + 1
            while j < n:
                var clash = False
                ref bj = edits.list[j]
                for k in range(i, j):
                    ref bk = edits.list[k]
                    if _intersects(bk, bk.x, bk.y, bk.w, bk.h, bj.x, bj.y, bj.w, bj.h):
                        clash = True
                        break
                if clash:
                    break
                j += 1
            self._wave(frame, edits, i, j)
            i = j
        self.millis = Float64(Int(now_ns()) - t0) / 1e6

    def _wave(mut self, mut frame: Frame, edits: Edits, first: Int, last: Int) raises:
        # Each edit's rectangle, cut to the frame, gathered one after another into stage (and its coverage into cov).
        var xs = List[Int]()
        var ys = List[Int]()
        var ws = List[Int]()
        var hs = List[Int]()
        var offs = List[Int]()
        var total = 0
        for k in range(first, last):
            ref e = edits.list[k]
            var x0 = max(e.x, 0)
            var y0 = max(e.y, 0)
            var x1 = min(e.x + e.w, frame.width)
            var y1 = min(e.y + e.h, frame.height)
            xs.append(x0)
            ys.append(y0)
            ws.append(max(x1 - x0, 0))
            hs.append(max(y1 - y0, 0))
            offs.append(total)
            total += ws[len(ws) - 1] * hs[len(hs) - 1]
        if total == 0:
            return
        self.stage.resize(total, 0)
        self.cov.resize(total, 0)
        for m in range(last - first):
            ref e = edits.list[first + m]
            for row in range(hs[m]):
                for col in range(ws[m]):
                    self.stage[offs[m] + row * ws[m] + col] = frame.pixels[(ys[m] + row) * frame.width + xs[m] + col]
                    if e.kind == PATCH:
                        self.cov[offs[m] + row * ws[m] + col] = edits.cov[e.offset + (ys[m] - e.y + row) * e.w + xs[m] - e.x + col]
        var done = False
        comptime if GPU_BUILD:
            if self.gpu.ctx:
                self._ensure(total)
                ref ctx = self.gpu.ctx.value()
                ref a = self.a.value()
                ref b = self.b.value()
                ctx.enqueue_copy(dst_buf=a.create_sub_buffer[DType.uint32](0, total), src_ptr=self.stage.unsafe_ptr())
                ctx.enqueue_copy(dst_buf=b.create_sub_buffer[DType.uint32](0, total), src_ptr=self.cov.unsafe_ptr())
                for m in range(last - first):
                    ref e = edits.list[first + m]
                    var w = ws[m]
                    var h = hs[m]
                    if w == 0 or h == 0:
                        continue
                    var da = a.unsafe_ptr().unsafe_offset(offs[m])
                    var grid = (ceildiv(w, 16), ceildiv(h, 16))
                    if e.kind == BLUR:
                        # the coverage buffer is also the blur's scratch: this edit's own slice of it
                        var db = b.unsafe_ptr().unsafe_offset(offs[m])
                        for _ in range(PASSES):
                            ctx.enqueue_function[_blur_kernel](da, db, Int32(w), Int32(h), Int32(e.radius), Int32(1), grid_dim=grid, block_dim=(16, 16))
                            ctx.enqueue_function[_blur_kernel](db, da, Int32(w), Int32(h), Int32(e.radius), Int32(0), grid_dim=grid, block_dim=(16, 16))
                    else:
                        var db = b.unsafe_ptr().unsafe_offset(offs[m])
                        ctx.enqueue_function[_compose_kernel](da, db, Int32(w), Int32(h), e.c1, e.c2, grid_dim=grid, block_dim=(16, 16))
                ctx.enqueue_copy(dst_ptr=self.stage.unsafe_ptr(), src_buf=a.create_sub_buffer[DType.uint32](0, total))
                ctx.synchronize()
                done = True
        if not done:
            self.scratch.resize(total, 0)
            var ps = _raw(self.stage.unsafe_ptr())
            var pc = _raw(self.cov.unsafe_ptr())
            var pt = _raw(self.scratch.unsafe_ptr())
            for m in range(last - first):
                ref e = edits.list[first + m]
                var w = ws[m]
                var h = hs[m]
                var o = offs[m]
                if e.kind == BLUR:
                    for _ in range(PASSES):
                        for y in range(h):
                            for x in range(w):
                                pt.unsafe_offset(o + y * w + x)[] = _blur_px(ps.unsafe_offset(o), w, h, x, y, e.radius, True)
                        for y in range(h):
                            for x in range(w):
                                ps.unsafe_offset(o + y * w + x)[] = _blur_px(pt.unsafe_offset(o), w, h, x, y, e.radius, False)
                else:
                    for k in range(w * h):
                        ps.unsafe_offset(o + k)[] = _compose_px(ps.unsafe_offset(o + k)[], pc.unsafe_offset(o + k)[], e.c1, e.c2)
        for m in range(last - first):
            for row in range(hs[m]):
                for col in range(ws[m]):
                    frame.pixels[(ys[m] + row) * frame.width + xs[m] + col] = self.stage[offs[m] + row * ws[m] + col]

    # ---- crop and scale ----

    def crop(mut self, frame: Frame, x: Int, y: Int, w: Int, h: Int, out_width: Int = 0, out_height: Int = 0, bilinear: Bool = False) raises -> Frame:
        """A new frame from a rectangle (cut to the frame), scaled to out_width × out_height if given (nearest, or bilinear)."""
        var x0 = max(x, 0)
        var y0 = max(y, 0)
        var cw = max(min(x + w, frame.width) - x0, 0)
        var ch = max(min(y + h, frame.height) - y0, 0)
        var ow = out_width if out_width > 0 else cw
        var oh = out_height if out_height > 0 else ch
        var out = Frame(ow, oh)
        if cw == 0 or ch == 0:
            return out^
        self.stage.resize(cw * ch, 0)
        for row in range(ch):
            for col in range(cw):
                self.stage[row * cw + col] = frame.pixels[(y0 + row) * frame.width + x0 + col]
        var done = False
        comptime if GPU_BUILD:
            if self.gpu.ctx:
                self._ensure(max(cw * ch, ow * oh))
                ref ctx = self.gpu.ctx.value()
                ref a = self.a.value()
                ref b = self.b.value()
                ctx.enqueue_copy(dst_buf=a.create_sub_buffer[DType.uint32](0, cw * ch), src_ptr=self.stage.unsafe_ptr())
                ctx.enqueue_function[_scale_kernel](
                    a.unsafe_ptr(), b.unsafe_ptr(), Int32(cw), Int32(ch), Int32(ow), Int32(oh), Int32(1 if bilinear else 0),
                    grid_dim=(ceildiv(ow, 16), ceildiv(oh, 16)), block_dim=(16, 16),
                )
                ctx.enqueue_copy(dst_ptr=out.pixels.unsafe_ptr(), src_buf=b.create_sub_buffer[DType.uint32](0, ow * oh))
                ctx.synchronize()
                done = True
        if not done:
            var ps = _raw(self.stage.unsafe_ptr())
            for yy in range(oh):
                for xx in range(ow):
                    out.pixels[yy * ow + xx] = _scale_px(ps, cw, ch, ow, oh, xx, yy, bilinear)
        return out^
