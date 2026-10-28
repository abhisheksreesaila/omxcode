# PointCloud as a simulation: step() moves every point in place, splat() adds each point's light to a pixel,
# points() reads them back; the GPU and the CPU agree. Run: pixi run mojo run -I . tests/test_pointcloud_step.mojo
from std.testing import assert_equal, assert_true

from mojoui import Surface
from mojoui.gpu import PointCloud, Point, Knobs, OUTSIDE, gpu_present


def fall(p: Point, k: Knobs) -> Point:
    """(x, y, vx, vy): gravity k[0], one step of k[1] seconds."""
    var vy = p[3] - k[0] * k[1]
    return Point(p[0] + p[2] * k[1], p[1] + vy * k[1], p[2], vy)


def pixel(p: Point, w: Int, h: Int, k: Knobs) -> Int:
    var px = Int(p[0] * Float32(w))
    var py = Int(p[1] * Float32(h))
    if p[0] < 0 or p[1] < 0 or px >= w or py >= h:
        return OUTSIDE
    return py * w + px


def red(p: Point, k: Knobs) -> SIMD[DType.float32, 4]:
    return SIMD[DType.float32, 4](0.25, Float32(0.5) if p[2] > 0 else Float32(0), 0, 0)


def cloud(n: Int, use_gpu: Bool) -> PointCloud:
    var pts = List[Float32](length=4 * n, fill=0)
    for i in range(n):
        pts[4 * i] = Float32(i % 64) / 64.0
        pts[4 * i + 1] = Float32((i // 64) % 64) / 64.0 + 0.5
        pts[4 * i + 2] = Float32(i % 3) * 0.1
    return PointCloud(pts^, use_gpu=use_gpu)


def test_step_moves_points_in_place() raises:
    var c = cloud(4096, False)
    var k = Knobs(9.8, 0.1, 0, 0, 0, 0, 0, 0)
    c.step[fall](k)
    c.step[fall](k)
    var p = c.points()
    assert_equal(len(p), 4 * 4096)
    # point 1: x = 1/64 + 2 × 0.1 × 0.1, vy = -2 × 0.98
    assert_true(abs(p[4 * 1] - (1.0 / 64.0 + 0.02)) < 1e-6)
    assert_true(abs(p[4 * 1 + 3] - Float32(-1.96)) < 1e-5)


def test_splat_adds_light_and_clamps() raises:
    var c = cloud(4096 * 4, False)  # every pixel of a 64 × 64 picture gets 4 points (y starts at 0.5: rows 32–63)
    var px = List[UInt32](length=64 * 64, fill=7)
    var s = Surface(Int(px.unsafe_ptr()), 64, 64, 1.0)
    c.splat[pixel, red](s, Knobs(0))
    assert_equal(px[0], UInt32(0xFF000000))  # black where nothing lands (the top half)
    var lit = px[40 * 64]  # x = 0: i % 3 varies, 4 points × 0.25 red = 1.0 → 255
    assert_equal(lit & 0xFF, UInt32(255))
    _ = len(px)


def test_gpu_matches_cpu() raises:
    if not gpu_present():
        print("  (no GPU: GPU half skipped)")
        return
    var g = cloud(100_000, True)
    var c = cloud(100_000, False)
    assert_true(g.on_gpu())
    var k = Knobs(9.8, 1.0 / 60.0, 0, 0, 0, 0, 0, 0)
    for _ in range(30):
        g.step[fall](k)
        c.step[fall](k)
    var a = g.points()
    var b = c.points()
    var worst = Float32(0)
    for i in range(len(a)):
        worst = max(worst, abs(a[i] - b[i]))
    assert_true(worst < 1e-4)
    var pa = List[UInt32](length=320 * 200, fill=0)
    var pb = List[UInt32](length=320 * 200, fill=0)
    var sa = Surface(Int(pa.unsafe_ptr()), 320, 200, 1.0)
    var sb = Surface(Int(pb.unsafe_ptr()), 320, 200, 1.0)
    g.splat[pixel, red](sa, k)
    c.splat[pixel, red](sb, k)
    var same = 0
    for i in range(len(pa)):
        if pa[i] == pb[i]:
            same += 1
    assert_true(same >= len(pa) - 10)  # (a point on a pixel's edge may land either side after 30 GPU steps)
    _ = len(pa)
    _ = len(pb)


def main() raises:
    test_step_moves_points_in_place()
    test_splat_adds_light_and_clamps()
    test_gpu_matches_cpu()
    print("test_pointcloud_step: ok")
