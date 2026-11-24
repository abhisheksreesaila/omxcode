# Goal 81, M6 (a Mac): a new glyph sends only the atlas rows it wrote. 120 random frames, each with a glyph or two never
# drawn before: the rows sent are those GlyphPages wrote since the last frame, never every row in use; the picture is
# within a level of the CPU executor, and the same, bit for bit, as a second renderer's that got every row at once. A
# restart of the pages (more glyphs than they hold) is in it too.
from std.testing import assert_true, assert_equal
from std.random import seed, random_ui64

from mojoui.canvas import Surface, rgba
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.fonttext import TextStyle, ALIGN_LEFT
from mojoui.gpu2d import GlyphAtlas, build_batches, execute_cpu, glyph_pages, DYN_ROWS
from mojoui.gpu2d_metal import Metal2D, read_iosurface
from mojoui.hosts.apple_canvas import io_surface

comptime W = 700
comptime H = 420


def pick(n: Int) -> Int:
    return Int(random_ui64(0, UInt64(n - 1)))


def maxdiff(a: List[UInt32], b: List[UInt32]) -> Int:
    var m = 0
    for i in range(len(a)):
        for c in range(3):
            m = max(m, abs(Int((a[i] >> UInt32(8 * c)) & 0xFF) - Int((b[i] >> UInt32(8 * c)) & 0xFF)))
    return m


def main() raises:
    seed(810)
    var font = Font()
    var atlas = GlyphAtlas(font)
    var mtl = Metal2D(atlas)
    assert_true(mtl.ok, "no Metal: " + mtl.why)
    var io = io_surface(W, H)
    var pg = glyph_pages(atlas.width)
    # glyphs at many sizes first: a few hundred rows in use
    var fill = Scene(W, H, 1.0)
    fill.begin_layer("fill")
    fill.fill(0xFFFFFFFF)
    for k in range(40):
        fill.run(TextStyle("Literata", 400, False, 10 + Float64(k)), "abcdefghijklmnopqrstuvwxyz0123456789", 5, 20 + Float64(k * 9), rgba(0, 0, 0), ALIGN_LEFT)
    assert_true(mtl.render(build_batches(fill, atlas, font), io, W, H), "the first frame")
    assert_true(pg[].used >= 200, "a few hundred rows before the new glyphs (" + String(pg[].used) + ")")
    var over = 0
    var frames = 0
    var worst = 0
    var most = 0
    var restarts = pg[].resets
    for n in range(120):
        var sc = Scene(W, H, 1.0)
        sc.begin_layer("a")
        sc.fill(0xFFF4F4F0)
        for k in range(6):
            sc.run(TextStyle("Literata", 400, False, 10 + Float64(pick(40))), "abc defg 0123", Float64(pick(400)), 30 + Float64(k * 60), rgba(20, 20, 60), ALIGN_LEFT)
        var size = 10 + Float64(n) * 0.37 + Float64(pick(20))  # (a size no glyph had: new ones)
        sc.run(TextStyle("Literata", 400, False, size), chr(0x0410 + pick(32)) + chr(0x41 + pick(26)), Float64(pick(500)), 60 + Float64(pick(300)), rgba(160, 30, 30), ALIGN_LEFT)
        var v0 = pg[].version
        var f = build_batches(sc, atlas, font)
        var wrote = pg[].rows_since(v0)
        var rows0 = mtl.page_rows
        assert_true(mtl.render(f, io, W, H), "frame " + String(n))
        var sent = mtl.page_rows - rows0
        most = max(most, sent)
        if sent > wrote[1] - wrote[0]:
            over += 1
        var got = read_iosurface(io, W, H)
        var want = List[UInt32](length=W * H, fill=0)
        var s = Surface(Int(want.unsafe_ptr()), W, H, 1.0)
        execute_cpu(f, atlas, s)
        worst = max(worst, maxdiff(got, want))
        if n % 20 == 19:
            var other = Metal2D(atlas)  # (nothing synced: every row at once)
            assert_true(other.ok, other.why)
            var io2 = io_surface(W, H)
            assert_true(other.render(f, io2, W, H), "the second renderer")
            assert_equal(maxdiff(read_iosurface(io2, W, H), got), 0, "a renderer that got every row draws another picture")
        frames += 1
    # past what the pages hold: they start again
    for n in range(60):
        var sc = Scene(W, H, 1.0)
        sc.begin_layer("a")
        sc.fill(0xFFF4F4F0)
        sc.run(TextStyle("Literata", 400, False, 60 + Float64(n)), "ABCDEFGHIJ", 5, 200, rgba(0, 0, 0), ALIGN_LEFT)
        var f = build_batches(sc, atlas, font)
        assert_true(mtl.render(f, io, W, H), "big frame")
        var want = List[UInt32](length=W * H, fill=0)
        var s = Surface(Int(want.unsafe_ptr()), W, H, 1.0)
        execute_cpu(f, atlas, s)
        worst = max(worst, maxdiff(read_iosurface(io, W, H), want))
        frames += 1
    print("  rows in use", pg[].used, "of", DYN_ROWS, "; most rows one frame sent", most, "; restarts", pg[].resets - restarts)
    print("FACT rows_over", over)
    print("FACT frames", frames)
    print("FACT worst", worst)
    print("FACT most_rows", most)
    print("gpu2d_metal_glyphs: ok")
