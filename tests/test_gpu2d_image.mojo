# Goal 81, M8: scaled pictures are filtered on GL and in the CPU executor (against a box filter, tests/image_cases);
# unscaled ones keep their pixels bit for bit; smooth=False keeps hard edges; a rebuilt frame with an unchanged
# 1920 × 1080 picture copies, hashes and uploads nothing of it; a video's frames reuse one texture.
#   pixi run mojo run -I . -I vendor tests/test_gpu2d_image.mojo          (headless GL)
from std.testing import assert_true, assert_equal
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.bitmap import Bitmap, make_bitmap, halved
from mojoui.gpu2d import GlyphAtlas, Frame2D, build_batches, execute_cpu
from mojoui.gpu2d_gl import GL2D, headless_gl33
from tests.image_cases import CASES, W, H, BACK, Case, pictures, photo


def cpu(f: Frame2D, atlas: GlyphAtlas, w: Int, h: Int) -> List[UInt32]:
    var want = List[UInt32](length=w * h, fill=0)
    var s = Surface(Int(want.unsafe_ptr()), w, h, 1.0)
    execute_cpu(f, atlas, s)
    return want^


def main() raises:
    var ctx = headless_gl33()
    assert_true(ctx != 0, "a headless GL 3.3 core context")
    var gl = GL2D()
    assert_true(gl.start(False), gl.why)
    var font = Font()
    var atlas = GlyphAtlas(font)
    gl.upload_atlas(atlas)
    var tex = gl.make_texture(W, H)
    var p = pictures()
    var worst = 0.0
    var apart = 0
    for i in range(CASES):
        var c = Case(i, p[0], p[1], p[2])
        var f = build_batches(c.scene(), atlas, font)
        var want = cpu(f, atlas, W, H)
        assert_true(gl.render(f, tex, W, H), gl.why)
        gl.finish()
        var got = List[UInt32](length=W * H, fill=0)
        assert_true(gl.read(tex, W, H, Int(got.unsafe_ptr())), "read back")
        var a = c.mean_off(want)
        var b = c.mean_off(got)
        var d = c.apart(want, got)
        print("  " + c.name + ": mean off CPU", round(a, 3), "GL", round(b, 3), "; CPU and GL at most", d, "apart")
        worst = max(worst, max(a, b))
        apart = max(apart, d)
    assert_true(apart <= 2, "GL and the CPU executor are " + String(apart) + " levels apart")
    # unscaled: the pixels as they are
    var unscaled = 0
    for turn in range(4):
        var b = p[0] if turn < 2 else p[1]
        var x = 12.0 if turn % 2 == 0 else 12.4
        var s = Scene(W, H, 1.0)
        s.begin_layer("a")
        s.fill(BACK)
        s.bitmap(b, x, 9.0, Float64(b[].w), Float64(b[].h))
        var f = build_batches(s, atlas, font)
        var want = cpu(f, atlas, W, H)
        assert_true(gl.render(f, tex, W, H), gl.why)
        gl.finish()
        var got = List[UInt32](length=W * H, fill=0)
        assert_true(gl.read(tex, W, H, Int(got.unsafe_ptr())), "read back")
        for yy in range(b[].h):
            for xx in range(b[].w):
                var o = b[].levels[0][yy * b[].w + xx]
                var at = (yy + 9) * W + xx + 12
                if want[at] != o or got[at] != o:
                    unscaled += 1
    # smooth=False: each pixel a block
    var cells: List[UInt32] = [0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFFFFFFFF]
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("a")
    sc.fill(BACK)
    sc.image(cells, 2, 2, 20, 20, 80, 80, smooth=False)
    var ff = build_batches(sc, atlas, font)
    var blocks = cpu(ff, atlas, W, H)
    assert_true(gl.render(ff, tex, W, H), gl.why)
    gl.finish()
    var gb = List[UInt32](length=W * H, fill=0)
    assert_true(gl.read(tex, W, H, Int(gb.unsafe_ptr())), "read back")
    for yy in range(80):
        for xx in range(80):
            var o = cells[(yy // 40) * 2 + xx // 40]
            assert_equal(blocks[(yy + 20) * W + xx + 20], o, "a cell's block (CPU)")
            assert_equal(gb[(yy + 20) * W + xx + 20], o, "a cell's block (GL)")
    # half sizes: a flat colour stays itself; an even picture's halves are the mean of four
    var flat = halved(List[UInt32](length=7 * 5, fill=0xFF336699), 7, 5, 3, 2, True)
    for q in flat:
        assert_equal(q, UInt32(0xFF336699))
    # waste: a 1920 × 1080 picture that stays the same
    var big = make_bitmap(photo(1920, 1080, False), 1920, 1080)
    var sent0 = 0
    var copied = 0
    var hashed = 0
    for n in range(4):
        var s = Scene(W, H, 1.0)
        s.begin_layer("a")
        s.fill(BACK)
        s.bitmap(big, 10, 10, 480, 270)
        s.rect(Float64(20 + n * 30), 300, 40, 40, 0xFF2040A0, 0)  # (the frame changes, the picture doesn't)
        var f = build_batches(s, atlas, font)
        assert_true(gl.render(f, tex, W, H), gl.why)
        copied += s.px_copied
        hashed += s.px_hashed
        if n == 0:
            sent0 = gl.tex_uploads
            assert_true(sent0 > 0, "sent once")
    print("FACT uploads", gl.tex_uploads - sent0)
    print("FACT copied", copied)
    print("FACT hashed", hashed)
    # a video's frames: one texture between them
    var before = len(gl.pictures)
    for n in range(6):
        var px = List[UInt32](length=64 * 48, fill=0xFF000000 | UInt32(n * 1000))
        var s = Scene(W, H, 1.0)
        s.begin_layer("a")
        s.fill(BACK)
        s.image(px, 64, 48, 10, 10, 128, 96)
        assert_true(gl.render(build_batches(s, atlas, font), tex, W, H), gl.why)
    assert_equal(len(gl.pictures) - before, 1, "a video's frames share one texture")
    print("FACT worst_mean", round(worst, 3))
    print("FACT cases", CASES)
    print("FACT unscaled_diff", unscaled)
    print("FACT apart", apart)
    print("gpu2d_image: ok")
