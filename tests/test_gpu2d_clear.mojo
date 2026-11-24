# Goal 80: a frame cleared to its opening fill's colour is the picture the fill drawn as a quad makes, and the CPU
# executor's. Every case × scales 1–2 (odd sizes), on one renderer reused in two orders (nothing left over from the frame
# before), through GPU2D.draw (layers, the ring) and GL2D.render; opening_fill finds exactly the fills that cover the canvas.
#   pixi run mojo run -I . tests/test_gpu2d_clear.mojo
from std.testing import assert_true, assert_equal

from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.scene import Scene
from mojoui.gpu2d import GlyphAtlas, Frame2D, build_batches, execute_cpu, opening_fill
from mojoui.gpu2d_gl import GPU2D, GL2D, headless_gl33
from tests.clear_cases import CASES, clear_case, clear_name, clears


def cpu_of(frame: Frame2D, atlas: GlyphAtlas) -> List[UInt32]:
    var px = List[UInt32](length=frame.width * frame.height, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), frame.width, frame.height, frame.scale)
    execute_cpu(frame, atlas, s)
    return px^


def maxdiff(a: List[UInt32], b: List[UInt32]) -> Int:
    var m = 0
    for i in range(len(a)):
        for c in range(4):
            m = max(m, abs(Int((a[i] >> UInt32(8 * c)) & 0xFF) - Int((b[i] >> UInt32(8 * c)) & 0xFF)))
    return m


def drawn(mut g: GPU2D, s: Scene) raises -> List[UInt32]:
    var slot = g.draw(s, Scene(0, 0, 1.0), 7, s.w, s.h)
    assert_true(slot >= 0, "draw: " + g.gl.why)
    var px = List[UInt32](length=s.w * s.h, fill=0)
    assert_true(g.gl.read(g.gl.tex[slot], s.w, s.h, Int(px.unsafe_ptr())), "read")
    return px^


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL 3.3 core context")
    var g = GPU2D()
    assert_true(g.start(False), g.gl.why)
    var gl = GL2D()
    assert_true(gl.start(False), gl.why)
    var font = Font()
    var atlas = GlyphAtlas(font)
    gl.upload_atlas(atlas)
    var worst = 0
    var n = 0
    for k in [1.0, 1.25, 1.5, 1.6, 2.0]:
        var w = Int(160 * k) + 1
        var h = Int(100 * k) + 1
        var tex = gl.make_texture(w, h)
        for turn in range(2):
            for i in range(CASES):
                var kind = i if turn == 0 else (i * 7 + 3) % CASES
                var s = clear_case(kind, w, h, k)
                var what = clear_name(kind) + " at " + String(k)
                var f = build_batches(s, atlas, font)
                ref l = f.layers[0]
                assert_equal(opening_fill(f, 0, l.dx, l.dy, l.k, w, h) >= 0, clears(kind), what + ": opening_fill")
                var want = cpu_of(f, atlas)
                var got = drawn(g, s)
                var d = maxdiff(got, want)
                worst = max(worst, d)
                assert_true(d <= 1, what + ": " + String(d) + " levels from the CPU executor")
                if clears(kind):
                    var q = clear_case(kind, w, h, k, quad=True)
                    var qf = build_batches(q, atlas, font)
                    assert_true(opening_fill(qf, 0, qf.layers[0].dx, qf.layers[0].dy, qf.layers[0].k, w, h) < 0, what + ": the quad's twin must not clear")
                    assert_equal(maxdiff(got, drawn(g, q)), 0, what + ": cleared and drawn as a quad differ")
                assert_true(gl.render(f, tex, w, h), gl.why)
                var r = List[UInt32](length=w * h, fill=0)
                assert_true(gl.read(tex, w, h, Int(r.unsafe_ptr())), "read")
                assert_true(maxdiff(r, want) <= 1, what + ": GL2D.render")
                # a cached layer moved after it was batched (a pan's first frames): its fill no longer reaches the canvas
                f.layers[0].dx += 30
                assert_true(opening_fill(f, 0, f.layers[0].dx, f.layers[0].dy, f.layers[0].k, w, h) < 0, what + ": moved, must not clear")
                want = cpu_of(f, atlas)
                assert_true(gl.render(f, tex, w, h), gl.why)
                assert_true(gl.read(tex, w, h, Int(r.unsafe_ptr())), "read")
                assert_true(maxdiff(r, want) <= 1, what + ": moved after batching")
                n += 1
        gl.delete(17, tex)
    print("  ", n, "frames; worst", worst, "levels from the CPU executor")
    print("gpu2d clear: ok")
