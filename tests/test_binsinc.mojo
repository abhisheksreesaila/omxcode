# Goal 79, D-7987: a tiled layer's op index (OpBins) built incrementally: the ops an edit's patch replays from the kept
# board keep their boxes from the index built for the version they were kept at; only the objects drawn again are
# measured. After the same 40 random edits as test_keptpatch (moves, new texts and stickies, deletes, colours, to front,
# undo, redo) the incremental index equals a fresh build each time: every box, the grid, and the ops a set of rects
# query. `binsinc: ok`.
#   pixi run mojo build -I . -I vendor tests/test_binsinc.mojo -o build/test_binsinc && build/test_binsinc
from std.testing import assert_true, assert_equal
from mojoui.scene import Scene
from mojoui.gpu2d_tiles import OpBins
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


def board_layer(sc: Scene) -> Int:
    for i in range(sc.layers()):
        if sc.layer_keys[i] == "board":
            return i
    return -1


def same_bins(mut a: OpBins, mut b: OpBins, what: String) raises:
    assert_equal(a.nops, b.nops, what + ": ops")
    for o in range(a.nops):
        assert_true(a.bx0[o] == b.bx0[o] and a.by0[o] == b.by0[o] and a.bx1[o] == b.bx1[o] and a.by1[o] == b.by1[o], what + ": box of op " + String(o))
    if len(a.extra) == 0:
        assert_true(a.nx == b.nx and a.ny == b.ny and a.cell == b.cell and a.gx0 == b.gx0 and a.gy0 == b.gy0, what + ": grid")
    if len(a.extra) == 0:  # (built whole: the same grid; patched in place, D-7999, it keeps the old grid and `extra`)
        assert_true(a.start == b.start and a.items == b.items, what + ": cells")
    for q in range(240):  # (what it answers is what counts: rects of every size, the whole board to a few px)
        var x = -900.0 + Float64((q * 7919) % 4200)
        var y = -700.0 + Float64((q * 104729) % 3000)
        var w = 8.0 * Float64(1 << (q % 10))
        assert_true(a.query(x, y, x + w, y + w * 0.7) == b.query(x, y, x + w, y + w * 0.7), what + ": query " + String(q))


def rnd(mut seed: UInt64) -> Int:
    seed = seed * 6364136223846793005 + 1442695040888963407
    return Int(seed >> 33)


def main() raises:
    var layer = board()
    var v = DeskView(-300, -200, 1.0)
    var look = BoardLook()
    var inc = OpBins()
    inc.incremental = True
    _ = scene_of(look, layer, v)
    var s0 = scene_of(look, layer, v)
    inc.build(s0, board_layer(s0))
    var reused = 0
    var measured = 0
    var builds = 0
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
        var i = board_layer(a)
        assert_true(i >= 0, "a board layer")
        inc.build(a, i)
        var fresh = OpBins()
        fresh.incremental = False
        fresh.build(a, i)
        same_bins(inc, fresh, "step " + String(step))
        reused += inc.reused
        measured += inc.nops - inc.reused
        if inc.reused > 0:
            builds += 1
    print("   patched in place (D-7999): " + String(inc.patched))
    assert_true(inc.patched >= 5, "some edits keep every op's place: patched in place")
    print("   40 edits: " + String(builds) + " builds took boxes from the one before; " + String(reused) + " boxes kept, " + String(measured) + " measured")
    assert_true(builds >= 30, "most builds incremental")
    assert_true(reused > 10 * measured, "most boxes kept")
    print("binsinc: ok")
