# Goal 36b M6b: drawing with the GPU's fixed-function blending. PointCloud.splat/paint write one vertex a point from the
# app's own Mojo place/tint (a GPU kernel), and mojoui.present blends them into a GL texture: additive (ONE, ONE) or
# "over" (SRC_ALPHA, ONE_MINUS_SRC_ALPHA, in point order), points or lines. With no window (EGL's device platform):
# additive points equal the compute splat's picture, lines light the pixels between their ends, "over" keeps point
# order, the CPU fallback agrees, and MOJOUI_BLEND=0 leaves the compute splat in charge.
# Run: pixi run mojo run -I . tests/test_canvas_blend.mojo
from std.testing import assert_equal, assert_true, assert_false
from std.ffi import external_call, c_int
from std.memory.alloc import alloc, Layout

from mojoui import Surface
from mojoui.gpu import PointCloud, Point, Knobs, OUTSIDE, gpu_present
from mojoui.present import Presenter, headless_gl


def place(p: Point, w: Int, h: Int, k: Knobs) -> Int:
    var px = Int(p[0] * Float32(w))
    var py = Int(p[1] * Float32(h))
    if p[0] < 0 or p[1] < 0 or px >= w or py >= h:
        return OUTSIDE
    return py * w + px


def tint(p: Point, k: Knobs) -> SIMD[DType.float32, 4]:
    return SIMD[DType.float32, 4](p[2] * k[0], p[3] * k[0], (p[2] + p[3]) * Float32(0.5) * k[0], 0)


def own(p: Point, k: Knobs) -> SIMD[DType.float32, 4]:
    """Colour from the point itself: (a, b) packed as r = a, g = b, opacity = b (for lines and "over")."""
    return SIMD[DType.float32, 4](p[2], Float32(1) - p[2], 0, p[3])


def cloud(n: Int) -> PointCloud:
    var pts = List[Float32](length=4 * n, fill=0)
    var s = UInt32(11)
    for i in range(4 * n):
        s ^= s << 13
        s ^= s >> 17
        s ^= s << 5
        pts[i] = Float32(s >> 8) * Float32(1.0 / 16777216.0)
    for i in range(n):
        if i % 2 == 0:
            pts[4 * i] = Float32(0.5) + (pts[4 * i] - Float32(0.5)) * Float32(0.05)
            pts[4 * i + 1] = Float32(0.5) + (pts[4 * i + 1] - Float32(0.5)) * Float32(0.05)
    return PointCloud(pts^)


def at(x: Int, y: Int, w: Int, h: Int, a: Float32, b: Float32) -> List[Float32]:
    """A point at pixel (x, y)'s centre."""
    return [(Float32(x) + 0.5) / Float32(w), (Float32(y) + 0.5) / Float32(h), a, b]


def chan(px: UInt32, c: Int) -> Int:
    return Int((px >> UInt32(8 * c)) & 255)


def setenv(name: String, value: String):
    var n = name
    var v = value
    _ = external_call["setenv", c_int](n.as_c_string_span(), v.as_c_string_span(), c_int(1))


def through(mut pr: Presenter, slot: Int, w: Int, h: Int) raises -> List[UInt32]:
    var got = List[UInt32](length=w * h, fill=0)
    assert_true(pr.read_slot(slot, Int(got.unsafe_ptr())))
    return got^


def main() raises:
    if not gpu_present():
        print("SKIP: no GPU")
        return
    var probe = PointCloud(List[Float32](length=4, fill=0))
    assert_true(headless_gl(probe.gpu.device) != 0, "a GL context with no window")
    var pp = alloc(Layout[Presenter].single()).unsafe_leak()
    pp.unsafe_write(Presenter())
    assert_true(pp[].start() and pp[].blend_ok, pp[].why + " / " + pp[].blend_why)
    print("  painter: " + pp[].blend_why)
    var k = Knobs(0.35, 0, 0, 0, 0, 0, 0, 0)

    # 1. Additive points: the GPU's blending = the compute splat, pixel for pixel
    var w = 1280
    var h = 720
    var c = cloud(300_000)
    var want = List[UInt32](length=w * h, fill=0)
    var sw = Surface(Int(want.unsafe_ptr()), w, h, 1.0)
    c.splat[place, tint](sw, k)  # (no painter offered: the compute splat, read back)
    var none = List[UInt32](length=w * h, fill=0)
    var sb = Surface(Int(none.unsafe_ptr()), w, h, 1.0)
    sb.gpu_ok = True
    sb.gpu_painter = Int(pp)
    c.blend_pref = 1  # (always blend: the choice between them is measured in the app's first frames)
    c.splat[place, tint](sb, k)
    assert_true(sb.gpu_slot >= 0 and c.blended == 1, "blended into a texture")
    assert_equal(sb.gpu_address, 0)
    var got = through(pp[], sb.gpu_slot, w, h)
    var diff = 0
    var worst = 0
    var lit = 0
    for i in range(w * h):
        if got[i] != want[i]:
            diff += 1
        for ch in range(3):
            worst = max(worst, abs(chan(got[i], ch) - chan(want[i], ch)))
        if want[i] != UInt32(0xFF000000):
            lit += 1
    print("  additive points, 300,000 on 1280×720: " + String(lit) + " lit pixels, " + String(diff) + " differ from the compute splat (worst " + String(worst) + " levels)")
    assert_true(lit > 1000)
    assert_true(worst <= 2, "within 2 levels")
    assert_equal(diff, 0, "equal to the compute splat (light in 1024ths is exact in float16 below 2.0)")

    # 2. Lines: a horizontal and a vertical segment, additive, on a small canvas; GPU and CPU light the same pixels
    w = 128
    h = 96
    var seg = at(10, 10, w, h, 0.5, 1) + at(50, 10, w, h, 0.5, 1) + at(100, 20, w, h, 0.5, 1) + at(100, 60, w, h, 0.5, 1)
    var lines = PointCloud(seg^)
    var buf = List[UInt32](length=w * h, fill=0)
    var sl = Surface(Int(buf.unsafe_ptr()), w, h, 1.0)
    sl.gpu_ok = True
    sl.gpu_painter = Int(pp)
    lines.paint[place, own](sl, k, lines=True)
    assert_true(sl.gpu_slot >= 0)
    var gl_lines = through(pp[], sl.gpu_slot, w, h)
    var cpu_buf = List[UInt32](length=w * h, fill=0)
    var sc = Surface(Int(cpu_buf.unsafe_ptr()), w, h, 1.0)
    lines.paint[place, own](sc, k, lines=True)  # (no painter: drawn on the CPU)
    var on_gl = 0
    var on_cpu = 0
    var same = 0
    for y in range(h):
        for x in range(w):
            var i = y * w + x
            var g_on = gl_lines[i] != UInt32(0xFF000000)
            var c_on = cpu_buf[i] != UInt32(0xFF000000)
            var inside = (y == 10 and 10 <= x <= 50) or (x == 100 and 20 <= y <= 60)
            if g_on:
                on_gl += 1
                assert_true(inside, "GL lit a pixel off the segments: " + String(x) + "," + String(y))
            if c_on:
                on_cpu += 1
                assert_true(inside, "the CPU lit a pixel off the segments")
            if g_on and c_on:
                same += 1
    print("  lines: GL lit " + String(on_gl) + " pixels, the CPU " + String(on_cpu) + ", both " + String(same) + " (segments of 40 and 40 pixels)")
    assert_true(on_gl >= 78 and on_cpu >= 78 and same >= 78, "both segments drawn end to end")
    assert_equal(chan(gl_lines[10 * w + 30], 0), 127, "half red (0.5 → 127)")

    # 3. "Over" keeps point order: opaque red then half-transparent green, and the other way round, at one pixel
    var two = at(5, 5, w, h, 1, 1) + at(5, 5, w, h, 0, 0.5) + at(9, 9, w, h, 0, 0.5) + at(9, 9, w, h, 1, 1)
    var ov = PointCloud(two^)
    var ob = List[UInt32](length=w * h, fill=0)
    var so = Surface(Int(ob.unsafe_ptr()), w, h, 1.0)
    so.gpu_ok = True
    so.gpu_painter = Int(pp)
    ov.paint[place, own](so, k, over=True)
    assert_true(so.gpu_slot >= 0)
    var gl_over = through(pp[], so.gpu_slot, w, h)
    var cpu_over = List[UInt32](length=w * h, fill=0)
    var sco = Surface(Int(cpu_over.unsafe_ptr()), w, h, 1.0)
    ov.paint[place, own](sco, k, over=True)
    var a = gl_over[5 * w + 5]
    var b = gl_over[9 * w + 9]
    print("  over: red then half green → (" + String(chan(a, 0)) + ", " + String(chan(a, 1)) + "); half green then red → (" + String(chan(b, 0)) + ", " + String(chan(b, 1)) + ")")
    assert_true(abs(chan(a, 0) - 127) <= 1 and abs(chan(a, 1) - 127) <= 1, "red under half green")
    assert_true(chan(b, 0) == 255 and chan(b, 1) == 0, "red over everything")
    for i in range(w * h):
        for ch in range(3):
            assert_true(abs(chan(gl_over[i], ch) - chan(cpu_over[i], ch)) <= 2, "GL and CPU 'over' agree")

    # 4. MOJOUI_BLEND=0: no painter; the compute splat leaves the picture in CUDA memory instead
    setenv("MOJOUI_BLEND", "0")
    var off = alloc(Layout[Presenter].single()).unsafe_leak()
    off.unsafe_write(Presenter())
    assert_true(off[].start() and not off[].blend_ok)
    var c2 = cloud(10_000)
    var b2 = List[UInt32](length=64 * 64, fill=0)
    var s2 = Surface(Int(b2.unsafe_ptr()), 64, 64, 1.0)
    s2.gpu_ok = True
    s2.gpu_painter = Int(off)
    c2.splat[place, tint](s2, k)
    assert_true(s2.gpu_slot < 0 and s2.gpu_address != 0, "the compute splat, its picture left in CUDA memory")
    print("  MOJOUI_BLEND=0: " + off[].blend_why + " → the compute splat")
    print("canvas blend: ok")
