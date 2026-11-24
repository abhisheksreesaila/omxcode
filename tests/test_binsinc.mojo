# Goal 79, D-7987: a tiled layer's op index (OpBins) built incrementally: the ops an edit's patch replays from the kept
# board keep their boxes from the index built for the version they were kept at; only the objects drawn again are
# measured. After the same 40 random edits as test_keptpatch (moves, new texts and stickies, deletes, colours, to front,
# undo, redo) and 20 objects carried far across the board, the index equals a fresh build each time (every box, and the ops
# 240 rects of every size query); it also answers as a scan of every op box by box. Run twice: patched in place (D-7999),
# and with that off, when the grid and cells must equal too (the strict equality this test always had). A mutant that
# forgets the ops kept beside the grid fails it (tried 11-23).
# `binsinc: ok`.
#   pixi run mojo build -I . -I vendor tests/test_binsinc.mojo -o build/test_binsinc && build/test_binsinc
from std.testing import assert_true, assert_equal
from mojoui.scene import Scene, OP_RUN
from mojoui.gpu2d_tiles import OpBins, op_box
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


def same_bins(mut a: OpBins, mut b: OpBins, what: String, strict: Bool) raises:
    """a answers as b, a fresh build: every box, 240 queries of every size; strict (built whole, MOJOUI_BINS_INPLACE=0):
    the same grid and cells too, as this test always asked."""
    assert_equal(a.nops, b.nops, what + ": ops")
    for o in range(a.nops):
        assert_true(a.bx0[o] == b.bx0[o] and a.by0[o] == b.by0[o] and a.bx1[o] == b.bx1[o] and a.by1[o] == b.by1[o], what + ": box of op " + String(o))
    if strict or len(a.extra) == 0:
        assert_true(a.nx == b.nx and a.ny == b.ny and a.cell == b.cell and a.gx0 == b.gx0 and a.gy0 == b.gy0, what + ": grid")
        assert_true(a.start == b.start and a.items == b.items, what + ": cells")
    for q in range(240):
        var r = rect_of(q)
        assert_true(a.query(r[0], r[1], r[2], r[3]) == b.query(r[0], r[1], r[2], r[3]), what + ": query " + String(q))


def rect_of(q: Int) -> Tuple[Float64, Float64, Float64, Float64]:
    var x = -900.0 + Float64((q * 7919) % 4200)
    var y = -700.0 + Float64((q * 104729) % 3000)
    var w = 8.0 * Float64(1 << (q % 10))
    return (x, y, x + w, y + w * 0.7)


def brute(sc: Scene, i: Int, mut bins: OpBins, x0: Float64, y0: Float64, x1: Float64, y1: Float64) -> List[Int]:
    """Every op of layer i tested one by one, its box measured from the scene itself (nothing of the index's grid, boxes
    or extra list): the ops, in paint order, whose boxes meet the rect."""
    var out = List[Int]()
    var span = sc.layer_range(i)
    for o in range(span[1] - span[0]):
        var op = span[0] + o
        var b = bins.run_box(sc, op) if Int(sc.kinds[op]) == OP_RUN else op_box(sc, op)
        if Float64(Float32(b[2])) < x0 or Float64(Float32(b[0])) > x1 or Float64(Float32(b[3])) < y0 or Float64(Float32(b[1])) > y1:
            continue
        out.append(o)
    return out^


def rnd(mut seed: UInt64) -> Int:
    seed = seed * 6364136223846793005 + 1442695040888963407
    return Int(seed >> 33)


def edits(in_place: Bool) raises:
    var layer = board()
    var v = DeskView(-300, -200, 1.0)
    var look = BoardLook()
    var inc = OpBins()
    inc.incremental = True
    inc.in_place = in_place
    var scan = OpBins()  # (only its text widths are used, by the brute-force scan)
    _ = scene_of(look, layer, v)
    var s0 = scene_of(look, layer, v)
    inc.build(s0, board_layer(s0))
    var reused = 0
    var measured = 0
    var builds = 0
    var scanned = 0
    var seed: UInt64 = 79
    var kinds = List[Int](length=7, fill=0)
    for step in range(60):
        var vis = BoardTools().visible_objects(layer, v, 1440, 900)
        var kind = rnd(seed) % 7
        kinds[kind] += 1
        var id = layer.objs[vis[rnd(seed) % len(vis)]].id
        if step >= 40:  # (twenty more: one object carried far, across many of the grid's cells, so an index that kept it
            # only where it was would miss it)
            layer.select(id, False)
            layer.begin_gesture(CH_MOVE)
            layer.move_by(Float64(rnd(seed) % 1400 - 700), Float64(rnd(seed) % 900 - 450))
            layer.end_gesture()
        elif kind == 0:  # a move
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
        same_bins(inc, fresh, "step " + String(step), not in_place)
        if step % 4 == 3 or len(inc.extra) > 0 and step % 2 == 0:  # (the property itself: a scan of every op's box)
            for q in range(0, 240, 5):
                var r = rect_of(q)
                assert_true(inc.query(r[0], r[1], r[2], r[3]) == brute(a, i, scan, r[0], r[1], r[2], r[3]), "step " + String(step) + ": brute force " + String(q))
            scanned += 1
        reused += inc.reused
        measured += inc.nops - inc.reused
        if inc.reused > 0:
            builds += 1
    print("   patched in place (D-7999): " + String(inc.patched))
    # (D-8006) another view in between, then back: the same board version draws another op list there, and the kept ops are
    # replayed whole when the first view returns; the index must not take the other list's boxes for them
    for trip in range(3):
        var away = scene_of(look, layer, v.zoomed_at(0.4 + 0.1 * Float64(trip), 720, 450))
        inc.build(away, board_layer(away))
        var far = OpBins()
        far.incremental = False
        far.build(away, board_layer(away))
        same_bins(inc, far, "away " + String(trip), not in_place)
        for _ in range(2):  # (the second paint replays the kept ops whole)
            var back = scene_of(look, layer, v)
            inc.build(back, board_layer(back))
            var f2 = OpBins()
            f2.incremental = False
            f2.build(back, board_layer(back))
            same_bins(inc, f2, "back " + String(trip), not in_place)
    if in_place:
        assert_true(inc.patched >= 5, "some edits keep every op's place: patched in place")
    else:
        assert_equal(inc.patched, 0, "built whole every time")
    assert_true(scanned >= 10, "checked against a scan of every op")
    print("   60 edits: " + String(builds) + " builds took boxes from the one before; " + String(reused) + " boxes kept, " + String(measured) + " measured")
    assert_true(builds >= 30, "most builds incremental")
    assert_true(reused > 10 * measured, "most boxes kept")


def main() raises:
    edits(True)  # (the index patched in place where it can be, D-7999)
    edits(False)  # (MOJOUI_BINS_INPLACE=0: built whole, strictly equal to a fresh build, grid and cells too)
    print("binsinc: ok")
