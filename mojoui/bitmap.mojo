# Pictures (goal 81, M8): pixels made once and shared. A Bitmap is a counted handle, so a Scene, the batches built from
# it and a kept layer all hold the same pixels: nothing copies them, and their hash (what a renderer knows them by) is
# made once, with them. Scaled, they are filtered: bilinear, and past 1.5× smaller from a chain of half-size copies
# (each pixel the average of the ones it covers), blended between two of them; see-through pixels weigh by their alpha.
# The GL and Metal renderers do the same arithmetic in their shaders (gpu2d_gl IMAGE_FS, gpu2d_metal image_f).
#
#   var b = make_bitmap(pixels^, w, h)     # once (pixels: w × h RGBA, R in the low byte, straight alpha)
#   painter.bitmap(b, x, y, width, height) # each frame: no copy, no hash, no upload of what the GPU has

from std.math import floor, log2
from std.memory import ArcPointer


struct BitmapData(Movable, Equatable):
    var w: Int
    var h: Int
    var opaque: Bool  # every pixel's alpha is 255
    var hash: UInt64  # of its pixels and size, never 0
    var levels: List[List[UInt32]]  # its pixels, then half sizes made when first needed (need)

    def __init__(out self, var pixels: List[UInt32], w: Int, h: Int):
        self.w = w
        self.h = h
        # (FNV-1a over four lanes at once: a video's frames are hashed as they come)
        comptime P = UInt64(1099511628211)
        var h0 = UInt64(14695981039346656037) ^ UInt64(w * h) ^ (UInt64(w) << 40)
        var h1 = h0 * P
        var h2 = h1 * P
        var h3 = h2 * P
        var alpha = UInt32(0xFF000000)
        var p = pixels.unsafe_ptr()
        var n = len(pixels)
        for i in range(0, n - 3, 4):
            var a = p[i]
            var b = p[i + 1]
            var c = p[i + 2]
            var d = p[i + 3]
            h0 = (h0 ^ UInt64(a)) * P
            h1 = (h1 ^ UInt64(b)) * P
            h2 = (h2 ^ UInt64(c)) * P
            h3 = (h3 ^ UInt64(d)) * P
            alpha &= a & b & c & d
        for i in range(n - n % 4, n):
            h0 = (h0 ^ UInt64(p[i])) * P
            alpha &= p[i]
        self.hash = (((h0 * P ^ h1) * P ^ h2) * P ^ h3) | 1
        self.opaque = alpha == 0xFF000000
        self.levels = List[List[UInt32]]()
        self.levels.append(pixels^)

    def __eq__(self, other: Self) -> Bool:
        return self.hash == other.hash and self.w == other.w and self.h == other.h

    def level_w(self, l: Int) -> Int:
        return max(self.w >> l, 1)

    def level_h(self, l: Int) -> Int:
        return max(self.h >> l, 1)

    def need(mut self, level: Int):
        """Makes the half sizes up to `level` (as far as 1 × 1) if they aren't there."""
        while len(self.levels) <= level and (self.level_w(len(self.levels) - 1) > 1 or self.level_h(len(self.levels) - 1) > 1):
            var l = len(self.levels)
            self.levels.append(halved(self.levels[l - 1], self.level_w(l - 1), self.level_h(l - 1), self.level_w(l), self.level_h(l), self.opaque))


comptime Bitmap = ArcPointer[BitmapData]


def make_bitmap(var pixels: List[UInt32], w: Int, h: Int) -> Bitmap:
    """w × h pixels as a Bitmap (more are dropped, missing ones are clear)."""
    var n = max(w, 0) * max(h, 0)
    if len(pixels) != n:
        pixels.resize(n, 0)
    return Bitmap(BitmapData(pixels^, max(w, 0), max(h, 0)))


def halved(src: List[UInt32], sw: Int, sh: Int, dw: Int, dh: Int, opaque: Bool) -> List[UInt32]:
    """The picture at half size: each pixel the mean of the part of the source it covers (an odd side's pixels weigh by
    how much of them is covered)."""
    var out = List[UInt32](length=dw * dh, fill=0)
    if opaque and sw == 2 * dw and sh == 2 * dh:  # (two channels at a time: photos and video frames)
        comptime M = UInt32(0x00FF00FF)
        var p = src.unsafe_ptr()
        var o = out.unsafe_ptr()
        for y in range(dh):
            var r0 = 2 * y * sw
            var r1 = r0 + sw
            for x in range(dw):
                var a = p[r0 + 2 * x]
                var b = p[r0 + 2 * x + 1]
                var c = p[r1 + 2 * x]
                var d = p[r1 + 2 * x + 1]
                var rb = (((a & M) + (b & M) + (c & M) + (d & M) + 0x00020002) >> 2) & M
                var ga = ((((a >> 8) & M) + ((b >> 8) & M) + ((c >> 8) & M) + ((d >> 8) & M) + 0x00020002) >> 2) & M
                o[y * dw + x] = rb | (ga << 8)
        return out^
    var kx = Float64(sw) / Float64(dw)
    var ky = Float64(sh) / Float64(dh)
    for y in range(dh):
        var y0 = Float64(y) * ky
        var y1 = y0 + ky
        for x in range(dw):
            var x0 = Float64(x) * kx
            var x1 = x0 + kx
            var r = 0.0
            var g = 0.0
            var b = 0.0
            var a = 0.0
            var sum = 0.0
            for sy in range(Int(y0), min(Int(y1 - 1e-9) + 1, sh)):
                var wy = min(y1, Float64(sy + 1)) - max(y0, Float64(sy))
                for sx in range(Int(x0), min(Int(x1 - 1e-9) + 1, sw)):
                    var w = wy * (min(x1, Float64(sx + 1)) - max(x0, Float64(sx)))
                    var c = src[sy * sw + sx]
                    var ca = Float64(Int(c >> 24)) * w
                    r += Float64(Int(c & 0xFF)) * ca
                    g += Float64(Int((c >> 8) & 0xFF)) * ca
                    b += Float64(Int((c >> 16) & 0xFF)) * ca
                    a += ca
                    sum += w
            if a > 0:
                out[y * dw + x] = (UInt32(Int(r / a + 0.5)) | (UInt32(Int(g / a + 0.5)) << 8) | (UInt32(Int(b / a + 0.5)) << 16)
                                   | (UInt32(Int(a / sum + 0.5)) << 24))
    return out^


def unscaled(pw: Int, ph: Int, w: Float64, h: Float64) -> Bool:
    """Drawn at its own size (to a hundredth of a pixel): its pixels as they are."""
    return abs(w - Float64(pw)) < 0.01 and abs(h - Float64(ph)) < 0.01


def lod_of(pw: Int, ph: Int, w: Float64, h: Float64) -> Float64:
    """Which half size a picture drawn w × h device pixels is read from (2.5: halfway between the second and the third).
    0 up to 1.5× smaller; from there on to the half size at 2×; then the logarithm."""
    if w <= 0 or h <= 0:
        return 0
    var r = max(Float64(pw) / w, Float64(ph) / h)
    if r <= 1.5:
        return 0
    if r < 2:
        return (r - 1.5) * 2
    return log2(r)


def levels_for(lod: Float64) -> Int:
    """The last level a picture at this lod is read from."""
    var l = Int(floor(lod))
    return l + 1 if lod > Float64(l) else l


struct Sampler(Movable):
    """A picture drawn w × h device pixels: the colour at (u, v) of it (0..1)."""
    var b: Bitmap
    var plain: Bool  # nearest: unscaled, or drawn that way
    var l0: Int
    var l1: Int
    var f: Float64

    def __init__(out self, b: Bitmap, w: Float64, h: Float64, smooth: Bool):
        self.b = b.copy()
        self.plain = not smooth or unscaled(b[].w, b[].h, w, h)
        var lod = 0.0 if self.plain else lod_of(b[].w, b[].h, w, h)
        self.b[].need(levels_for(lod))
        var last = len(self.b[].levels) - 1
        self.l0 = min(Int(floor(lod)), last)
        self.l1 = min(self.l0 + 1, last)
        self.f = min(lod - Float64(self.l0), 1.0) if self.l1 > self.l0 else 0.0

    def _level(self, l: Int, u: Float64, v: Float64) -> SIMD[DType.float64, 4]:
        """Level l at (u, v), bilinear, premultiplied."""
        ref px = self.b[].levels[l]
        var w = self.b[].level_w(l)
        var h = self.b[].level_h(l)
        var x = u * Float64(w) - 0.5
        var y = v * Float64(h) - 0.5
        var fx = floor(x)
        var fy = floor(y)
        var tx = x - fx
        var ty = y - fy
        var x0 = min(max(Int(fx), 0), w - 1)
        var y0 = min(max(Int(fy), 0), h - 1)
        var x1 = min(max(Int(fx) + 1, 0), w - 1)
        var y1 = min(max(Int(fy) + 1, 0), h - 1)
        return (_pre(px[y0 * w + x0]) * ((1 - tx) * (1 - ty)) + _pre(px[y0 * w + x1]) * (tx * (1 - ty))
                + _pre(px[y1 * w + x0]) * ((1 - tx) * ty) + _pre(px[y1 * w + x1]) * (tx * ty))

    def at(self, u: Float64, v: Float64) -> UInt32:
        if self.plain:
            var w = self.b[].w
            var h = self.b[].h
            return self.b[].levels[0][min(max(Int(floor(v * Float64(h))), 0), h - 1) * w + min(max(Int(floor(u * Float64(w))), 0), w - 1)]
        var c = self._level(self.l0, u, v)
        if self.f > 0:
            c = c * (1 - self.f) + self._level(self.l1, u, v) * self.f
        if c[3] <= 0:
            return 0
        var k = 1.0 / c[3]
        return (UInt32(Int(c[0] * k * 255.0 + 0.5)) | (UInt32(Int(c[1] * k * 255.0 + 0.5)) << 8) | (UInt32(Int(c[2] * k * 255.0 + 0.5)) << 16)
                | (UInt32(Int(c[3] * 255.0 + 0.5)) << 24))


@always_inline
def _pre(c: UInt32) -> SIMD[DType.float64, 4]:
    var a = Float64(Int(c >> 24)) / 255.0
    return SIMD[DType.float64, 4](Float64(Int(c & 0xFF)) / 255.0 * a, Float64(Int((c >> 8) & 0xFF)) / 255.0 * a, Float64(Int((c >> 16) & 0xFF)) / 255.0 * a, a)
