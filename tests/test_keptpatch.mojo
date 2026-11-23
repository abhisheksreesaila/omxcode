# Goal 79, D-7974: an edit patches the kept board ops in place: the objects it changed (or added) painted again, every
# other object's kept ops replayed in the layer's order, gone ones dropped. After 40 random edits on the stress board
# (moves, new texts and stickies, deletes, colours, bring to front, undo, redo) each patched paint's ops equal a full
# walk's op for op, and every few steps the GL renderer's frames are pixel-identical. `keptpatch: ok`.
#   pixi run mojo run -I . -I vendor tests/test_keptpatch.mojo
from std.testing import assert_true, assert_equal
from mojoui.scene import Scene, KeptOps, OP_IMAGE, OP_POLY, OP_STROKE, STRIDE
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.pagedesk import DeskView, BoardLook, BoardTools
from mojoui.objectlayer import ObjectLayer, import_json_canvas, CH_MOVE

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



def rnd(mut seed: UInt64) -> Int:
    seed = seed * 6364136223846793005 + 1442695040888963407
    return Int(seed >> 33)


def main() raises:
    var layer = board()
    var v = DeskView(-300, -200, 1.0)
    var look = BoardLook()
    var walk = BoardLook()
    walk.keep_ops = False
    _ = scene_of(look, layer, v)
    _ = scene_of(look, layer, v)
    _ = scene_of(walk, layer, v)
    assert_true(headless_gl33() != 0, "a headless GL context")
    var g1 = GPU2D()
    assert_true(g1.start(False), "start")
    var g2 = GPU2D()
    assert_true(g2.start(False), "start")
    var seed: UInt64 = 79
    var kinds = List[Int](length=7, fill=0)
    for step in range(40):
        var vis = BoardTools().visible_objects(layer, v, 1440, 900)
        var kind = rnd(seed) % 7
        kinds[kind] += 1
        var id = layer.objs[vis[rnd(seed) % len(vis)]].id
        if kind == 0:  # a move
            layer.select(id, False)
            layer.begin_gesture(CH_MOVE)
            layer.move_by(Float64(rnd(seed) % 40 - 20), Float64(rnd(seed) % 30 - 15))
            layer.end_gesture()
        elif kind == 1:
            _ = layer.add_text(Float64(rnd(seed) % 900), Float64(rnd(seed) % 600), 200, 60, "made at step " + String(step))
        elif kind == 2:
            _ = layer.add_sticky(Float64(rnd(seed) % 900), Float64(rnd(seed) % 600), 180, "sticky " + String(step))
        elif kind == 3:
            layer.delete(id)
        elif kind == 4:
            layer.set_color(id, 0xFF000000 | UInt32(rnd(seed) & 0xFFFFFF))
        elif kind == 5:
            layer.select(id, False)
            layer.bring_to_front()
        else:
            _ = layer.undo() if rnd(seed) % 2 == 0 else layer.redo()
        var a = scene_of(look, layer, v)
        var b = scene_of(walk, layer, v)
        same_ops(a, b, "step " + String(step))
        if step % 8 == 7:
            var d = differ(pixels(g1, a), pixels(g2, b))
            assert_equal(d, 0, "pixel-identical at step " + String(step))
    print("   40 edits (moves, texts, stickies, deletes, colours, to front, undo/redo: " + String(kinds[0]) + "/" + String(kinds[1]) + "/" + String(kinds[2]) + "/" + String(kinds[3]) + "/" + String(kinds[4]) + "/" + String(kinds[5]) + "/" + String(kinds[6]) + "): " + String(look.patches) + " patched, ops identical each time, frames identical every 8th")
    assert_true(look.patches >= 30, "most edits patched")
    g1.gl.close()
    g2.gl.close()
    print("keptpatch: ok")
