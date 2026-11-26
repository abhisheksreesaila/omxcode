# Goal 80: test_gpu2d_clear's cases on Metal: cleared to the opening fill = the fill drawn as a quad (exactly), and within
# 2 levels of the CPU executor. A Mac only; built as tests/test_gpu2d_metal.mojo is.
from std.testing import assert_true, assert_equal

from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.gpu2d import GlyphAtlas, build_batches, execute_cpu
from mojoui.gpu2d_metal import Metal2D, read_iosurface
from mojoui.hosts.apple_canvas import io_surface
from tests.clear_cases import CASES, clear_case, clear_name, clears


def maxdiff(a: List[UInt32], b: List[UInt32]) -> Int:
    var m = 0
    for i in range(len(a)):
        for c in range(3):
            m = max(m, abs(Int((a[i] >> UInt32(8 * c)) & 0xFF) - Int((b[i] >> UInt32(8 * c)) & 0xFF)))
    return m


def main() raises:
    var font = Font()
    var atlas = GlyphAtlas(font)
    var mtl = Metal2D(atlas)
    assert_true(mtl.ok, "no Metal: " + mtl.why)
    var worst = 0
    for k in [1.0, 1.5, 1.6, 2.0]:
        var w = Int(160 * k) + 1
        var h = Int(100 * k) + 1
        var io = io_surface(w, h)
        for turn in range(2):
            for i in range(CASES):
                var kind = i if turn == 0 else (i * 7 + 3) % CASES
                var what = clear_name(kind) + " at " + String(k)
                var f = build_batches(clear_case(kind, w, h, k), atlas, font)
                var want = List[UInt32](length=w * h, fill=0)
                var s = Surface(Int(want.unsafe_ptr()), w, h, k)
                execute_cpu(f, atlas, s)
                assert_true(mtl.render(f, io, w, h), what + ": Metal didn't draw it")
                var got = read_iosurface(io, w, h)
                if clears(kind):
                    assert_true(mtl.render(build_batches(clear_case(kind, w, h, k, quad=True), atlas, font), io, w, h), "quad")
                    assert_equal(maxdiff(got, read_iosurface(io, w, h)), 0, what + ": cleared and drawn as a quad differ")
                var d = maxdiff(got, want)
                worst = max(worst, d)
                assert_true(d <= 2, what + ": " + String(d) + " levels from the CPU executor")
    print("  worst", worst, "levels from the CPU executor")
    print("metal clear: ok")
