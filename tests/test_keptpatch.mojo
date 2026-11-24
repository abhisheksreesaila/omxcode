# Goal 79, D-7974: an edit patches the kept board ops in place: the objects it changed (or added) painted again, every
# other object's kept ops replayed in the layer's order, gone ones dropped. After 40 random edits on the stress board
# (moves, new texts and stickies, deletes, colours, bring to front, undo, redo) each patched paint's ops equal a full
# walk's op for op, and every few steps the GL renderer's frames are pixel-identical; (D-7978) the edits' damage comes
# from ObjectLayer's change log (the tiled frames would differ if a damage were missed). `keptpatch: ok`.
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


def scene_of(mut look: BoardLook, mut layer: ObjectLayer, v: DeskView, lifted: List[Int] = List[Int]()) -> Scene:
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("bg")
    sc.fill(0xFFF0F2F5)
    look.paint(sc, layer, v, 1440, 900, K, lifted)
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
    print("   (D-7978) looks answered from the change log: " + String(look.fills))
    assert_true(look.fills >= 30, "edits' damage from the change log, not a compare over every object")
    # (D-8010) the view moves between edits: pans past the tiles the kept ops cover and back, zooms in and out, each with
    # an edit or two (a move, a new sticky, an undo) meanwhile; the paint equals a full walk's ops each time, frames
    # pixel-identical every few, and it is a patch: objects that stay in view replay, only the new ones are painted
    var pv = v
    var p1 = look.patches
    var moved = 0
    for step in range(36):
        var r = rnd(seed) % 5
        if r == 0:
            pv = pv.zoomed_at(pv.scale * (0.7 + 0.1 * Float64(rnd(seed) % 8)), 300 + Float64(rnd(seed) % 800), 200 + Float64(rnd(seed) % 500))
            pv.scale = max(0.2, min(2.5, pv.scale))
        elif r <= 2:
            pv.x += Float64(rnd(seed) % 1400 - 700)
            pv.y += Float64(rnd(seed) % 900 - 450)
        if rnd(seed) % 3 == 0:
            var vis = BoardTools().visible_objects(layer, pv, 1440, 900)
            if len(vis) > 0:
                layer.select(layer.objs[vis[rnd(seed) % len(vis)]].id, False)
                layer.begin_gesture(CH_MOVE)
                layer.move_by(Float64(rnd(seed) % 60 - 30), Float64(rnd(seed) % 40 - 20))
                layer.end_gesture()
        elif rnd(seed) % 6 == 0:
            _ = layer.add_sticky(pv.to_page(300, 200)[0], pv.to_page(300, 200)[1], 120, "view " + String(step))
        elif rnd(seed) % 7 == 0:
            _ = layer.undo()
        var a = scene_of(look, layer, pv)
        var b = scene_of(walk, layer, pv)
        same_ops(a, b, "view step " + String(step))
        moved += 1
        if step % 6 == 5:
            assert_equal(differ(pixels(g1, a), pixels(g2, b)), 0, "view step " + String(step) + ": pixel-identical")
    assert_true(look.patches - p1 >= 20, "views moved: most paints patched, not walked: " + String(look.patches - p1) + " of " + String(moved))
    print("   (D-8010) " + String(moved) + " view moves with edits: " + String(look.patches - p1) + " patched, ops identical each time")
    # (D-8005) a drag: the press that lifts some objects (and the connectors that end at them), moves, the drop, a second
    # drag straight after, and an edit elsewhere during one: the patched paint equals a full walk with the same lift each
    # frame, its tiled frames pixel-identical; lifting and dropping are patches too, not full walks
    var p0 = look.patches
    var lifts = 0
    var worst = 0
    for round_ in range(8):
        var vis = BoardTools().visible_objects(layer, v, 1440, 900)
        var some = List[Int]()
        var want = 1 + round_ * 4
        for t in range(want):
            var id = layer.objs[vis[(round_ * 37 + t * 11) % len(vis)]].id
            if id not in some:
                some.append(id)
                layer.select(id, t > 0)
        layer.begin_gesture(CH_MOVE)
        for frame in range(5):
            if frame > 0:
                layer.move_by(Float64(frame) * 6, Float64(frame) * 4)
            if frame == 3 and round_ % 3 == 0:  # (something else changes mid-drag)
                _ = layer.add_text(40, 30 + Float64(round_) * 9, 160, 40, "meanwhile " + String(round_))
            var a = scene_of(look, layer, v, some)
            var b = scene_of(walk, layer, v, some)
            same_ops(a, b, "lift " + String(round_) + " frame " + String(frame))
            if frame == 0 or frame == 4 and round_ % 2 == 0:
                var d = differ(pixels(g1, a), pixels(g2, b))
                worst = max(worst, d)
                assert_equal(d, 0, "lift " + String(round_) + ": pixel-identical at frame " + String(frame))
        layer.end_gesture()
        var a = scene_of(look, layer, v)
        var b = scene_of(walk, layer, v)
        same_ops(a, b, "drop " + String(round_))
        assert_equal(differ(pixels(g1, a), pixels(g2, b)), 0, "drop " + String(round_) + ": pixel-identical")
        lifts += 1
    assert_true(look.patches - p0 >= 2 * lifts, "lifts and drops patched, not walked: " + String(look.patches - p0))
    print("   (D-8005) " + String(lifts) + " lifts and drops: " + String(look.patches - p0) + " patched paints, ops and pixels identical")
    g1.gl.close()
    g2.gl.close()
    print("keptpatch: ok")
