# Goal 81, M8: scaled pictures for test_gpu2d_image (GL and the CPU executor) and test_gpu2d_metal_image (a Mac): a
# photo-like picture (value noise whose octaves halve, as a photo's spectrum falls, with hard-edged shapes in it),
# opaque or see-through, even or odd sized, at 0.25, 0.5, 0.8 and 1.7 times its size, on whole and fractional pixels; and
# the oracle: each pixel the mean of the part of the picture it covers.
from std.math import floor
from mojoui.bitmap import Bitmap, make_bitmap
from mojoui.scene import Scene

comptime CASES = 16
comptime W = 620
comptime H = 460
comptime BACK = UInt32(0xFFB0C8E0)


def _hash(x: Int, y: Int, s: Int) -> Float64:
    var h = UInt64(x * 73856093) ^ UInt64(y * 19349663) ^ UInt64(s * 83492791)
    h = (h ^ (h >> 13)) * 0x9E3779B97F4A7C15
    return Float64(Int((h >> 40) & 0xFFFF)) / 65535.0


def _noise(x: Float64, y: Float64, s: Int) -> Float64:
    var x0 = Int(floor(x))
    var y0 = Int(floor(y))
    var tx = x - Float64(x0)
    var ty = y - Float64(y0)
    tx = tx * tx * (3 - 2 * tx)
    ty = ty * ty * (3 - 2 * ty)
    var a = _hash(x0, y0, s) * (1 - tx) + _hash(x0 + 1, y0, s) * tx
    var b = _hash(x0, y0 + 1, s) * (1 - tx) + _hash(x0 + 1, y0 + 1, s) * tx
    return a * (1 - ty) + b * ty


def photo(w: Int, h: Int, alpha: Bool) -> List[UInt32]:
    var out = List[UInt32](capacity=w * h)
    for y in range(h):
        for x in range(w):
            var px = UInt32(0)
            for c in range(3):
                var v = 0.0
                var amp = 0.5
                var f = 1.0 / 64.0
                for o in range(6):
                    v += amp * _noise(Float64(x) * f, Float64(y) * f, c * 10 + o)
                    amp *= 0.5
                    f *= 2
                var dx = x - w // 3
                var dy = y - h // 2
                if dx * dx + dy * dy < (h // 5) * (h // 5):
                    v = 0.25 + 0.5 * v
                px |= UInt32(min(max(Int(v * 255.0 + 0.5), 0), 255)) << UInt32(8 * c)
            var a = UInt32(255)
            if alpha:
                a = UInt32(min(max(Int(_noise(Float64(x) / 40.0, Float64(y) / 40.0, 99) * 400.0 - 70.0), 0), 255))
            out.append(px | (a << 24))
    return out^


struct Case(Movable):
    var name: String
    var b: Bitmap
    var x: Float64
    var y: Float64
    var w: Float64
    var h: Float64

    def __init__(out self, i: Int, even: Bitmap, odd: Bitmap, clear: Bitmap):
        var scales: List[Float64] = [0.25, 0.5, 0.8, 1.7]
        var k = scales[i % 4]
        var which = i // 4
        self.b = even.copy() if which < 2 else (odd.copy() if which == 2 else clear.copy())
        self.x = 10.0 if which == 0 else 7.3
        self.y = 8.0 if which == 0 else 9.7
        self.w = Float64(self.b[].w) * k
        self.h = Float64(self.b[].h) * k
        self.name = ["even", "even, between pixels", "odd", "see-through"][which] + " at " + String(k)

    def scene(self) -> Scene:
        var s = Scene(W, H, 1.0)
        s.begin_layer("a")
        s.fill(BACK)
        s.bitmap(self.b, self.x, self.y, self.w, self.h)
        return s^

    def oracle(self, qx: Int, qy: Int) -> SIMD[DType.float64, 4]:
        """The pixel's colour over BACK (0..255): the mean of the part of the picture it covers."""
        var u0 = (Float64(qx) - self.x) / self.w * Float64(self.b[].w)
        var u1 = (Float64(qx + 1) - self.x) / self.w * Float64(self.b[].w)
        var v0 = (Float64(qy) - self.y) / self.h * Float64(self.b[].h)
        var v1 = (Float64(qy + 1) - self.y) / self.h * Float64(self.b[].h)
        var sum = SIMD[DType.float64, 4](0)
        var area = 0.0
        for sy in range(max(Int(floor(v0)), 0), min(Int(floor(v1 - 1e-9)) + 1, self.b[].h)):
            var wy = min(v1, Float64(sy + 1)) - max(v0, Float64(sy))
            for sx in range(max(Int(floor(u0)), 0), min(Int(floor(u1 - 1e-9)) + 1, self.b[].w)):
                var w = wy * (min(u1, Float64(sx + 1)) - max(u0, Float64(sx)))
                var c = self.b[].levels[0][sy * self.b[].w + sx]
                var a = Float64(Int(c >> 24)) / 255.0
                for k in range(3):
                    sum[k] += (Float64(Int((c >> UInt32(8 * k)) & 0xFF)) * a + Float64(Int((BACK >> UInt32(8 * k)) & 0xFF)) * (1 - a)) * w
                area += w
        return sum / max(area, 1e-9)

    def mean_off(self, px: List[UInt32]) -> Float64:
        """The picture drawn in px against the oracle: the mean of the differences (levels) over its inner pixels."""
        var sum = 0.0
        var n = 0
        for qy in range(Int(self.y) + 2, Int(self.y + self.h) - 2):
            for qx in range(Int(self.x) + 2, Int(self.x + self.w) - 2):
                var want = self.oracle(qx, qy)
                var got = px[qy * W + qx]
                for k in range(3):
                    sum += abs(Float64(Int((got >> UInt32(8 * k)) & 0xFF)) - want[k])
                    n += 1
        return sum / Float64(max(n, 1))


    def apart(self, a: List[UInt32], b: List[UInt32]) -> Int:
        """The most two drawings of it differ by, the rim left out: a pixel whose centre is on the picture's very edge (an
        80 % picture's edge at 178.5) is in or out by the last bit of a float, on a GPU or not."""
        var m = 0
        for qy in range(H):
            for qx in range(W):
                var cx = Float64(qx) + 0.5
                var cy = Float64(qy) + 0.5
                if min(abs(cx - self.x), abs(cx - self.x - self.w)) < 0.01 or min(abs(cy - self.y), abs(cy - self.y - self.h)) < 0.01:
                    continue
                for c in range(3):
                    m = max(m, abs(Int((a[qy * W + qx] >> UInt32(8 * c)) & 0xFF) - Int((b[qy * W + qx] >> UInt32(8 * c)) & 0xFF)))
        return m


def pictures() -> Tuple[Bitmap, Bitmap, Bitmap]:
    return (make_bitmap(photo(320, 240, False), 320, 240), make_bitmap(photo(301, 211, False), 301, 211), make_bitmap(photo(256, 200, True), 256, 200))
