# Goal 79, D-7963: a layer's ops kept from one paint and replayed in the next (Painter.ops_capture / ops_replay,
# BoardLook's kept board). (1) a replayed board's ops equal a fresh walk's op for op (kinds, numbers, colours, texts,
# images, polygon and stroke points, notes); (2) on the real GL renderer (headless) the replayed frame is pixel-identical
# to the walked one; (3) an edit, a pan past the cull rect, a zoom and a lift each invalidate it (the next paint walks)
# and still match a fresh walk; (4) the CPU painter can't keep ops (ops_replay False) and draws as before. `keptops: ok`.
#   pixi run mojo run -I . -I vendor tests/test_keptops.mojo
from std.testing import assert_true, assert_equal
from mojoui.canvas import Surface
from mojoui.scene import Scene, SurfacePainter, KeptOps, OP_IMAGE, OP_POLY, OP_STROKE, STRIDE
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.pagedesk import DeskView, BoardLook, BoardTools
from mojoui.objectlayer import ObjectLayer, import_json_canvas, CH_MOVE
from mojoui.canvasload import OpenBoard

comptime W = 2304
comptime H = 1440
comptime K = 1.6


def board() -> ObjectLayer:
    try:
        var f = open("build/g79/race/note-stress.json", "r")
        var t = f.read()
        f.close()
        var l = import_json_canvas(t)
        l.set_connector_gap(6)
        return l^
    except:
        var l = ObjectLayer()
        for i in range(1200):
            var x = Float64(i % 40) * 120
            var y = Float64(i // 40) * 110
            if i % 2 == 0:
                _ = l.add_text(x, y, 110, 40, "Text " + String(i))
            else:
                _ = l.add_sticky(x, y, 90, "Sticky " + String(i))
        return l^


def scene_of(mut look: BoardLook, mut layer: ObjectLayer, v: DeskView) -> Scene:
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("bg")
    sc.fill(0xFFF0F2F5)
    look.paint(sc, layer, v, 1440, 900, K)
    return sc^


def same_ops(a: Scene, b: Scene, what: String) raises:
    assert_equal(a.ops(), b.ops(), what + ": op count")
    for op in range(a.ops()):
        assert_equal(Int(a.kinds[op]), Int(b.kinds[op]), what + ": kind")
        assert_equal(a.colors[op], b.colors[op], what + ": colour")
        var kind = Int(a.kinds[op])
        for c in range(STRIDE):
            if kind == OP_IMAGE and c == 4 or (kind == OP_POLY or kind == OP_STROKE) and c == 0:
                continue  # (an index: compared through what it points at below)
            assert_equal(a.nums[op * STRIDE + c], b.nums[op * STRIDE + c], what + ": number")
        assert_equal(a.text_at(op), b.text_at(op), what + ": text")
        if kind == OP_POLY or kind == OP_STROKE:
            for q in range(Int(a.nums[op * STRIDE + 1])):
                assert_equal(a.poly_x(op, q), b.poly_x(op, q), what + ": point")
                assert_equal(a.poly_y(op, q), b.poly_y(op, q), what + ": point")
        if kind == OP_IMAGE:
            assert_true(a.images[Int(a.nums[op * STRIDE + 4])] == b.images[Int(b.nums[op * STRIDE + 4])], what + ": image")
        assert_equal(a.meaning_of(op), b.meaning_of(op), what + ": note")
    for i in range(a.layers()):
        assert_equal(a.layer_keys[i], b.layer_keys[i])
        assert_equal(a.layer_range(i)[0], b.layer_range(i)[0])


def pixels(mut g: GPU2D, sc: Scene) raises -> List[UInt32]:
    var s = g.draw(sc, Scene(0, 0, 1.0), 1, W, H)
    assert_true(s >= 0, "draw: " + g.gl.why)
    while g.more:
        s = g.draw(sc, sc, 1, W, H)
    var px = List[UInt32](length=W * H, fill=0)
    assert_true(g.gl.read(g.gl.tex[s], W, H, Int(px.unsafe_ptr())), "read")
    return px^


def differ(a: List[UInt32], b: List[UInt32]) -> Int:
    var n = 0
    for i in range(len(a)):
        if a[i] != b[i]:
            n += 1
    return n


def check(name: String, mut kept: BoardLook, mut layer: ObjectLayer, v: DeskView, want_replay: Bool, mut g: GPU2D) raises:
    """Two paints with the kept look (the second may replay), against a look that always walks."""
    var r0 = kept.replays
    var a = scene_of(kept, layer, v)
    var walk = BoardLook()
    walk.keep_ops = False
    var b = scene_of(walk, layer, v)
    same_ops(a, b, name)
    if want_replay:
        assert_true(kept.replays > r0, name + ": replayed")
    else:
        assert_equal(kept.replays, r0, name + ": walked (invalidated)")
    var gw = GPU2D()
    assert_true(gw.start(False), "start ref")
    var d = differ(pixels(g, a), pixels(gw, b))
    gw.gl.close()
    print("   " + name + ": " + String(a.ops()) + " ops, " + ("replayed" if kept.replays > r0 else "walked") + ", " + String(d) + " pixels differ")
    assert_equal(d, 0, name + ": pixel-identical")


def main() raises:
    var layer = board()
    print("   board:", len(layer.objs), "objects")
    var v = DeskView(-300, -200, 1.0)
    var look = BoardLook()
    _ = scene_of(look, layer, v)  # (the first paint walks; the second walks again and keeps)
    _ = scene_of(look, layer, v)
    assert_true(headless_gl33() != 0, "a headless GL context")
    var g = GPU2D()
    assert_true(g.start(False), "start")
    check("the same board again", look, layer, v, True, g)
    # an edit: the board's version moves, the next paint walks
    var vis = BoardTools().visible_objects(layer, v, 1440, 900)
    layer.select(layer.objs[vis[len(vis) // 2]].id, False)
    layer.begin_gesture(CH_MOVE)
    layer.move_by(31, 17)
    layer.end_gesture()
    check("after an edit", look, layer, v, False, g)
    _ = scene_of(look, layer, v)  # (it holds: kept again)
    check("the edited board again", look, layer, v, True, g)
    # a pan past the cull rect's tile, a zoom that shows more: not replayed whole (D-8010: patched, what came in painted)
    # (D-8010) a zoom that stays inside the cull rect: the ops are in page px, so the kept ones are replayed
    check("zoomed inside the cull rect", look, layer, DeskView(-300, -200, 1.02), True, g)
    check("panned 700 px", look, layer, DeskView(-1000, -200, 1.0), False, g)
    check("zoomed", look, layer, DeskView(-300, -200, 0.8), False, g)
    # a lift (a drag's objects drawn above the board): the board without them is walked
    var lifted = List[Int]()
    lifted.append(layer.objs[vis[len(vis) // 3]].id)
    var r0 = look.replays
    var la = Scene(W, H, 1.0)
    look.paint(la, layer, v, 1440, 900, K, lifted)
    assert_equal(look.replays, r0, "a lift walks")
    var walk = BoardLook()
    walk.keep_ops = False
    var lb = Scene(W, H, 1.0)
    walk.paint(lb, layer, v, 1440, 900, K, lifted)
    same_ops(la, lb, "lifted")
    # (5) a progressive open: the kept look against a walking look, slice by slice
    var text = String("")
    try:
        var f = open("build/g79/race/note-stress.json", "r")
        text = f.read()
        f.close()
    except:
        pass
    if text != "":
        var ob = OpenBoard()
        var vo = DeskView(-300, -200, 1.0)
        assert_equal(ob.open(text, -900, -700, 2300, 1500, 6), "")
        var lk = BoardLook()
        var lw = BoardLook()
        lw.keep_ops = False
        var slices = 0
        var r_open = lk.replays
        while True:
            var a = scene_of(lk, ob.layer, vo)
            var b = scene_of(lw, ob.layer, vo)
            same_ops(a, b, "open slice " + String(slices))
            slices += 1
            if not ob.step(-900, -700, 2300, 1500, 800):
                break
        var a2 = scene_of(lk, ob.layer, vo)
        var b2 = scene_of(lw, ob.layer, vo)
        same_ops(a2, b2, "open complete")
        print("   a progressive open: " + String(slices) + " slices, " + String(lk.replays - r_open) + " replayed, each op for op with a walk")
        assert_true(lk.replays - r_open > 0, "slices outside the view replay the kept ops")
    # the CPU painter keeps nothing
    var buf = List[UInt32](length=64 * 64, fill=0)
    var sp = SurfacePainter(Surface(Int(buf.unsafe_ptr()), 64, 64, 1.0))
    assert_equal(sp.ops_mark(), -1)
    assert_true(not sp.ops_replay(KeptOps()), "the CPU painter can't replay")
    g.gl.close()
    _ = len(buf)
    print("keptops: ok · " + String(look.replays) + " replays")
