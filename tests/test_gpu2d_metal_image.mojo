# Goal 81, M8 (a Mac): test_gpu2d_image's cases on Metal: scaled pictures filtered (against the box filter), within 2 levels
# of the CPU executor; unscaled ones bit for bit; an unchanged 1920 × 1080 picture sent once; smooth=False keeps blocks.
from std.testing import assert_true, assert_equal
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.bitmap import Bitmap, make_bitmap
from mojoui.gpu2d import GlyphAtlas, Frame2D, build_batches, execute_cpu
from mojoui.gpu2d_metal import Metal2D, read_iosurface
from mojoui.hosts.apple_canvas import io_surface
from tests.image_cases import CASES, W, H, BACK, Case, pictures, photo


def main() raises:
    var font = Font()
    var atlas = GlyphAtlas(font)
    var mtl = Metal2D(atlas)
    assert_true(mtl.ok, "no Metal: " + mtl.why)
    var io = io_surface(W, H)
    var p = pictures()
    var worst = 0.0
    var apart = 0
    for i in range(CASES):
        var c = Case(i, p[0], p[1], p[2])
        var f = build_batches(c.scene(), atlas, font)
        var want = List[UInt32](length=W * H, fill=0)
        var s = Surface(Int(want.unsafe_ptr()), W, H, 1.0)
        execute_cpu(f, atlas, s)
        assert_true(mtl.render(f, io, W, H), c.name)
        var got = read_iosurface(io, W, H)
        var b = c.mean_off(got)
        var d = c.apart(want, got)
        print("  " + c.name + ": mean off Metal", round(b, 3), "; CPU and Metal at most", d, "apart")
        worst = max(worst, b)
        apart = max(apart, d)
    assert_true(apart <= 2, "Metal and the CPU executor are " + String(apart) + " levels apart")
    var unscaled = 0
    for turn in range(4):
        var b = p[0] if turn < 2 else p[1]
        var s = Scene(W, H, 1.0)
        s.begin_layer("a")
        s.fill(BACK)
        s.bitmap(b, 12.0 if turn % 2 == 0 else 12.4, 9.0, Float64(b[].w), Float64(b[].h))
        assert_true(mtl.render(build_batches(s, atlas, font), io, W, H), "unscaled")
        var got = read_iosurface(io, W, H)
        for yy in range(b[].h):
            for xx in range(b[].w):
                if got[(yy + 9) * W + xx + 12] != b[].levels[0][yy * b[].w + xx]:
                    unscaled += 1
    var cells: List[UInt32] = [0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFFFFFFFF]
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("a")
    sc.fill(BACK)
    sc.image(cells, 2, 2, 20, 20, 80, 80, smooth=False)
    assert_true(mtl.render(build_batches(sc, atlas, font), io, W, H), "cells")
    var gb = read_iosurface(io, W, H)
    for yy in range(80):
        for xx in range(80):
            assert_equal(gb[(yy + 20) * W + xx + 20], cells[(yy // 40) * 2 + xx // 40], "a cell's block (Metal)")
    var big = make_bitmap(photo(1920, 1080, False), 1920, 1080)
    var sent0 = 0
    for n in range(4):
        var s = Scene(W, H, 1.0)
        s.begin_layer("a")
        s.fill(BACK)
        s.bitmap(big, 10, 10, 480, 270)
        s.rect(Float64(20 + n * 30), 300, 40, 40, 0xFF2040A0, 0)
        assert_true(mtl.render(build_batches(s, atlas, font), io, W, H), "big")
        if n == 0:
            sent0 = mtl.pic_uploads
    print("FACT uploads", mtl.pic_uploads - sent0)
    print("FACT worst_mean", round(worst, 3))
    print("FACT unscaled_diff", unscaled)
    print("FACT apart", apart)
    assert_equal(unscaled, 0)
    print("gpu2d_metal_image: ok")
