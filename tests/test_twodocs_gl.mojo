# Review 3, MUST 1 and 2 and SHOULD 1 on the GPU renderer: two big boards whose ids, versions and counts collide, one
# renderer, switched A → B → A: each frame is the open document's, pixel for pixel as a fresh renderer draws it: opened
# whole, with a kept view (B held while A's tiles are there: B's kept view in its first frame, never A's, never blank),
# as kept parses, under one look and under a look per document. `twodocs gl: ok`.  (a GPU program: scripts/gpu-free first)
from std.testing import assert_true, assert_equal
from std.os import getenv
from std.time import perf_counter_ns
from mojoui.libc import unlink
from mojoui.scene import Scene
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.viewsnap import snap_read, snap_dir_ready
from mojoui.pagedesk import DeskView, BoardLook
from mojoui.objectlayer import ObjectLayer

comptime W = 2304
comptime H = 1440
comptime K = 1.6


def board(word: String, bare: Int) -> ObjectLayer:
    """1,200 stickies; `bare`: which quarter of the window holds none (tiles empty in one document and not in the other)."""
    var l = ObjectLayer()
    for i in range(1200):
        var x = Float64(i % 40) * 120 - 400
        var y = Float64(i // 40) * 110 - 300
        if (bare == 1 and x < 800 and x > 200 and y < 500) or (bare == 2 and x >= 800 and y >= 300):
            y += 20000
        _ = l.add_sticky(x, y, 90, word + " " + String(i))
    return l^


def frame(mut g: GPU2D, mut look: BoardLook, mut layer: ObjectLayer, v: DeskView) raises -> List[UInt32]:
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("bg")
    sc.fill(0xFFF0F2F5)
    look.paint(sc, layer, v, 1440, 900, K)
    var s = g.draw(sc, Scene(0, 0, 1.0), 1, W, H)
    assert_true(s >= 0, "draw")
    var px = List[UInt32](length=W * H, fill=0)
    assert_true(g.gl.read(g.gl.tex[s], W, H, Int(px.unsafe_ptr())), "read")
    return px^


def differ(a: List[UInt32], b: List[UInt32]) -> Int:
    var n = 0
    for i in range(len(a)):
        if a[i] != b[i]:
            n += 1
    return n


def alone(mut layer: ObjectLayer, v: DeskView, path: String = "", tag: String = "") raises -> List[UInt32]:
    """The document drawn by a renderer of its own (its view kept at path when asked)."""
    var g = GPU2D()
    assert_true(g.start(False), "start")
    var look = BoardLook()
    look.keep_path = path
    look.keep_tag = tag
    var px = frame(g, look, layer, v)
    var t0 = perf_counter_ns()
    while path != "" and not snap_read(path, True).ok and perf_counter_ns() - t0 < 6_000_000_000:
        _ = frame(g, look, layer, v)
    g.gl.close()
    return px^


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    var dir = getenv("TMPDIR", "/tmp") + "/viewsnap-twodocs"
    assert_true(snap_dir_ready(dir), "folder")
    var v = DeskView(-300, -200, 1.0)
    var a = board("AAA", 1)
    var b = board("BEE", 2)
    _ = unlink(dir + "/a.snap")
    _ = unlink(dir + "/b.snap")
    var wa = alone(a, v, dir + "/a.snap", "doc=a")
    var wb = alone(b, v, dir + "/b.snap", "doc=b")
    assert_true(differ(wa, wb) > 10000, "two pictures")
    # one look, one renderer, A B A B, three frames each
    var g = GPU2D()
    assert_true(g.start(False), "start")
    var look = BoardLook()
    for round in range(2):
        for f in range(3):
            assert_equal(differ(frame(g, look, a, v), wa), 0, "A, frame " + String(f))
        for f in range(3):
            assert_equal(differ(frame(g, look, b, v), wb), 0, "B after A, frame " + String(f))
    # with kept views: B opens held (its objects not in yet) while A's tiles are the renderer's
    for round in range(2):
        for d in range(2):
            var empty = ObjectLayer()
            look.keep_path = dir + ("/a.snap" if d == 0 else "/b.snap")
            look.keep_tag = "doc=a" if d == 0 else "doc=b"
            look.keep_hold = True
            for f in range(2):
                var px = frame(g, look, empty, v)
                assert_equal(differ(px, wa if d == 0 else wb), 0, "held, " + look.keep_tag + " frame " + String(f) + ": its kept view")
            look.keep_hold = False
            for f in range(3):
                var px = frame(g, look, a, v) if d == 0 else frame(g, look, b, v)
                assert_equal(differ(px, wa if d == 0 else wb), 0, "in, " + look.keep_tag + " frame " + String(f))
    look.keep_path = ""
    look.keep_tag = ""
    # a look per document, the same renderer and canvas
    var la = BoardLook()
    var lb = BoardLook()
    for round in range(2):
        for f in range(2):
            assert_equal(differ(frame(g, la, a, v), wa), 0, "A's look, frame " + String(f))
        for f in range(2):
            assert_equal(differ(frame(g, lb, b, v), wb), 0, "B's look, frame " + String(f))
    # looks made anew for each open (versions that start alike)
    for round in range(3):
        var na = BoardLook()
        assert_equal(differ(frame(g, na, a, v), wa), 0, "a new look for A")
        var nb = BoardLook()
        assert_equal(differ(frame(g, nb, b, v), wb), 0, "a new look for B")
    g.gl.close()
    print("twodocs gl: ok")
