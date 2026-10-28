# Goal 36b M6: a GPU Canvas picture goes to the screen without a GPU→CPU readback. PointCloud.splat leaves its
# picture on the GPU when the host can take one (surface.gpu_ok); mojoui.present copies it GPU→GPU into a GL texture
# (CUDA↔GL). Here, with no window (a GL context on the GPU through EGL's device platform), the texture is read back
# and must equal the CPU-readback picture byte for byte. Also: the texture ring never hands out a texture the
# toolkit still holds, and the run-time choice says why when the GPU path isn't available.
# Run: pixi run mojo run -I . tests/test_canvas_present.mojo
from std.testing import assert_equal, assert_true, assert_false
from std.ffi import external_call, c_int
from std.memory import Pointer
from std.memory.alloc import alloc, Layout

from mojoui import Surface
from mojoui.gpu import PointCloud, Point, Knobs, OUTSIDE, gpu_present
from mojoui.present import Presenter, headless_gl, SLOTS


def place(p: Point, w: Int, h: Int, k: Knobs) -> Int:
    var px = Int(p[0] * Float32(w))
    var py = Int(p[1] * Float32(h))
    if p[0] < 0 or p[1] < 0 or px >= w or py >= h:
        return OUTSIDE
    return py * w + px


def tint(p: Point, k: Knobs) -> SIMD[DType.float32, 4]:
    return SIMD[DType.float32, 4](p[2] * k[0], p[3] * k[0], (p[2] + p[3]) * Float32(0.5) * k[0], 0)


def cloud(n: Int, use_gpu: Bool) -> PointCloud:
    """Points piled towards the middle (so some pixels saturate), with light that varies point by point."""
    var pts = List[Float32](length=4 * n, fill=0)
    var s = UInt32(7)
    for i in range(4 * n):
        s ^= s << 13
        s ^= s >> 17
        s ^= s << 5
        pts[i] = Float32(s >> 8) * Float32(1.0 / 16777216.0)
    for i in range(n):  # x, y towards 0.5 for every other point
        if i % 2 == 0:
            pts[4 * i] = Float32(0.5) + (pts[4 * i] - Float32(0.5)) * Float32(0.05)
            pts[4 * i + 1] = Float32(0.5) + (pts[4 * i + 1] - Float32(0.5)) * Float32(0.05)
    return PointCloud(pts^, use_gpu=use_gpu)


def setenv(name: String, value: String):
    var n = name
    var v = value
    _ = external_call["setenv", c_int](n.as_c_string_span(), v.as_c_string_span(), c_int(1))


def unsetenv(name: String):
    var n = name
    _ = external_call["unsetenv", c_int](n.as_c_string_span())


def picture_through_gl(mut pr: Presenter, mut c: PointCloud, w: Int, h: Int, k: Knobs) raises -> List[UInt32]:
    var none = List[UInt32](length=w * h, fill=0)
    var s = Surface(Int(none.unsafe_ptr()), w, h, 1.0)
    s.gpu_ok = True
    var before = c.read_back
    c.splat[place, tint](s, k)
    assert_true(s.gpu_drawn and s.gpu_address != 0, "the picture stayed on the GPU")
    assert_equal(c.read_back, before, "no readback when the host takes a GPU picture")
    assert_equal(s.gpu_device, pr.device)
    for i in range(w * h):
        assert_equal(none[i], UInt32(0), "the surface's CPU memory was never written")
    var slot = pr.acquire(w, h)
    assert_true(slot >= 0)
    assert_true(pr.copy_in(slot, s.gpu_address, w, h), "CUDA → GL copy: " + pr.why)
    var got = List[UInt32](length=w * h, fill=0)
    assert_true(pr.read_slot(slot, Int(got.unsafe_ptr())), "read the texture back")
    return got^


def main() raises:
    if not gpu_present():
        print("SKIP: no GPU")
        return
    # 1. No GL context current: the choice says so (the canvas keeps the copy)
    var nogl = Presenter()
    assert_false(nogl.start())
    print("  without a GL context: " + nogl.why)
    assert_true(nogl.why.find("isn't on a CUDA GPU") >= 0 or nogl.why.find("no OpenGL") >= 0, nogl.why)
    # 2. Turned off
    setenv("MOJOUI_CANVAS_GPU", "0")
    var off = Presenter()
    assert_false(off.start())
    assert_true(off.why.find("turned off") >= 0, off.why)
    print("  MOJOUI_CANVAS_GPU=0: " + off.why)
    unsetenv("MOJOUI_CANVAS_GPU")
    # 3. A GL context on the GPU the clouds use
    var probe = PointCloud(List[Float32](length=4, fill=0))
    var dev = probe.gpu.device
    var gl = headless_gl(dev)
    assert_true(gl != 0, "a GL context on CUDA device " + String(dev) + " (EGL device platform)")
    var pp = alloc(Layout[Presenter].single()).unsafe_leak()  # (lives at a fixed address, as a host's does)
    pp.unsafe_write(Presenter())
    assert_true(pp[].start(), pp[].why)
    print("  presenter: " + pp[].why)
    assert_equal(pp[].device, dev, "the GL context's GPU is the cloud's")
    var k = Knobs(0.35, 0, 0, 0, 0, 0, 0, 0)
    var sizes: List[Tuple[Int, Int]] = [(1280, 720), (333, 197)]
    for sz in sizes:
        var w = sz[0]
        var h = sz[1]
        var c = cloud(300_000, True)
        assert_true(c.on_gpu())
        # the CPU-readback picture (goal 36's path) and the CPU-only one
        var want = List[UInt32](length=w * h, fill=0)
        var sw = Surface(Int(want.unsafe_ptr()), w, h, 1.0)
        c.splat[place, tint](sw, k)
        assert_true(sw.gpu_drawn and sw.gpu_address == 0)
        var cpu = cloud(300_000, False)
        var plain = List[UInt32](length=w * h, fill=0)
        var sp = Surface(Int(plain.unsafe_ptr()), w, h, 1.0)
        cpu.splat[place, tint](sp, k)
        var got = picture_through_gl(pp[], c, w, h, k)
        var lit = 0
        var white = 0
        for i in range(w * h):
            assert_equal(want[i], plain[i], "GPU = CPU picture")
            assert_equal(got[i], want[i], "GL texture = readback picture, byte for byte")
            if got[i] != UInt32(0xFF000000):
                lit += 1
            if got[i] == UInt32(0xFFFFFFFF):
                white += 1
        assert_true(lit > 1000 and white > 0, "a picture with light and saturated pixels")
        print("  " + String(w) + "×" + String(h) + ": GL texture = readback picture, byte for byte (" + String(lit) + " lit, " + String(white) + " white pixels)")
    # 4. The ring: a texture the toolkit holds is never handed out again until it's released
    var held = List[Int]()
    for _ in range(SLOTS):
        var s = pp[].acquire(64, 32)
        assert_true(s >= 0)
        for h in held:
            assert_true(h != s, "a held texture handed out twice")
        Pointer[Int, MutUntrackedOrigin](unsafe_from_address=pp[].busy_flag(s))[] = 1
        held.append(s)
    assert_equal(pp[].acquire(64, 32), -1, "every texture held: none handed out")
    Pointer[Int, MutUntrackedOrigin](unsafe_from_address=pp[].busy_flag(held[2]))[] = 0  # (the toolkit lets go of one)
    assert_equal(pp[].acquire(64, 32), held[2], "the released one comes back")
    print("  ring: " + String(SLOTS) + " held → none handed out; the one released comes back")
    print("canvas present: ok")
