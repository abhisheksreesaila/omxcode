# Goal 79, D-7940: a whole board kept as raster tiles, end to end. mojoui.pagedesk's BoardLook paints Personal Note's
# stress note (5,296 objects, build/g79/race/note-stress.json; or the 600-object note, or a generated board) into a
# tiled layer whose damage comes from mojoui.damage; mojoui.objectlayer edits it (a move, new words, a colour, a delete,
# undo and redo, a drag whose objects are lifted out of the tiles and dropped back, a pan, a zoom that settles; review 2:
# a resize, a z-order change, ink added and erased, a connector re-routed by its end moving, a rotation, a zoom out over
# kept tiles (D-7947's strips), and a progressive open's slices landing over kept tiles). After
# each, the frame GPU2D draws from its tiles must equal a direct render of the same scene (goal 75's M1 bounds, and at
# most 64 pixels more than 8 levels off), and the tiles re-rastered after an edit must be few (partial: the damage only).
# Prints each step's tiles and the time of the frame (paint + draw, CPU + GPU, glFinish). `boardraster: ok`.
#   pixi run mojo run -I . tests/test_boardraster.mojo
from std.testing import assert_true
from std.time import perf_counter_ns
from mojoui.scene import Scene
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.pagedesk import DeskView, BoardLook, opening_view, PAGE_W, PAGE_H
from mojoui.objectlayer import ObjectLayer, import_json_canvas, TEXT, STICKY, CONNECTOR, INK, CH_MOVE, CH_GESTURE, H_SE
from mojoui.ink import Stroke
from mojoui.canvasload import OpenBoard

comptime W = 2304
comptime H = 1440
comptime K = 1.6


def load(path: String) -> ObjectLayer:
    try:
        var f = open(path, "r")
        var t = f.read()
        f.close()
        var l = import_json_canvas(t)
        l.set_connector_gap(6)
        return l^
    except:
        var l = ObjectLayer()
        for i in range(600):
            var x = Float64(i % 30) * 120
            var y = Float64(i // 30) * 110
            if i % 2 == 0:
                _ = l.add_text(x, y, 100, 40, "Text " + String(i))
            else:
                _ = l.add_sticky(x, y, 90, "Sticky " + String(i))
        return l^


def scene_of(mut look: BoardLook, mut layer: ObjectLayer, v: DeskView, lifted: List[Int] = List[Int]()) -> Scene:
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("bg")
    sc.fill(0xFFF0F2F5)
    look.paint(sc, layer, v, 1440, 900, K, lifted)
    return sc^


def pixels(mut g: GPU2D, sc: Scene, prev: Scene) raises -> List[UInt32]:
    var s = g.draw(sc, prev, 1, W, H)
    assert_true(s >= 0, "draw: " + g.gl.why)
    var px = List[UInt32](length=W * H, fill=0)
    assert_true(g.gl.read(g.gl.tex[s], W, H, Int(px.unsafe_ptr())), "read")
    return px^


def direct(sc: Scene) raises -> List[UInt32]:
    var g = GPU2D()
    assert_true(g.start(False), "start")
    g.tiles_on = False
    var px = pixels(g, sc, Scene(0, 0, 1.0))
    g.gl.close()
    return px^


def check(name: String, mut g: GPU2D, sc: Scene, prev: Scene, max_rastered: Int = -1) raises:
    var t0 = perf_counter_ns()
    var got = pixels(g, sc, prev)
    var ms = Float64(Int(perf_counter_ns() - t0)) / 1e6
    var r = g.tiles.rastered
    var dmg = g.tiles.damaged
    while g.more:  # (later frames fill what this one left)
        got = pixels(g, sc, sc)
    var want = direct(sc)
    var total = 0
    var worst = 0
    var far = 0
    var bx0 = W
    var by0 = H
    var bx1 = -1
    var by1 = -1
    var nbad = 0
    for i in range(len(want)):
        var w0 = 0
        for c in range(3):
            var d = abs(Int((want[i] >> UInt32(8 * c)) & 0xFF) - Int((got[i] >> UInt32(8 * c)) & 0xFF))
            total += d
            w0 = max(w0, d)
        worst = max(worst, w0)
        if w0 > 40:
            far += 1
        if w0 > 8:
            bx0 = min(bx0, i % W)
            by0 = min(by0, i // W)
            bx1 = max(bx1, i % W)
            by1 = max(by1, i // W)
            nbad += 1
    var mean = Float64(total) / Float64(3 * len(want))
    if nbad > 0:
        var at = by0 * W + bx0
        print("   (pixels more than 8 off:", nbad, "in x", bx0, "-", bx1, "y", by0, "-", by1, "; first: want", hex(want[at]), "got", hex(got[at]),
              "; around want", hex(want[at - 1]), hex(want[at + 1]), "got", hex(got[at - 1]), hex(got[at + 1]), ")")
    print("  ", name, ": tiles rastered", r, "(damaged", String(dmg) + "), frame", round(ms, 2), "ms; tiled vs direct: mean", round(mean, 4), "worst", worst)
    # (M1's bounds, goal 75: mean ≤ 1.5 levels, ≤ 0.5 % of pixels more than 40 off; and stricter, at most 64 pixels with
    # a channel more than 8 off (a polygon edge's stencil sample can flip at another translation; a stale tile is
    # thousands of pixels tens of levels off)
    assert_true(mean <= 1.5 and Float64(far) <= 0.005 * Float64(len(want)) and nbad <= 64, name + ": the tiled board differs from a direct render")
    if max_rastered >= 0:
        assert_true(r <= max_rastered, name + ": more tiles rastered than the edit needed")


def pick(layer: ObjectLayer, kind: Int, v: DeskView) -> Int:
    """An object of this kind in the middle of the window (its id)."""
    var best = -1
    var bd = 1e300
    for ref o in layer.objs:
        if o.kind != kind:
            continue
        var c = v.to_screen(o.x + o.w / 2, o.y + o.h / 2)
        var d = (c[0] - 720) ** 2 + (c[1] - 450) ** 2
        if d < bd:
            bd = d
            best = o.id
    return best


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    var layer = load("build/g79/race/note-stress.json")
    print("   board:", len(layer.objs), "objects")
    var look = BoardLook()
    var v = DeskView(-300, -200, 1.0)  # (100 %, a few pages in)
    var g = GPU2D()
    assert_true(g.start(False), "start")
    var prev = Scene(0, 0, 1.0)
    var sc = scene_of(look, layer, v)
    check("open at 100 %", g, sc, prev)
    prev = sc^
    # a move (one undo step)
    var a = pick(layer, STICKY, v)
    layer.clear_selection()
    layer.select(a)
    layer.begin_gesture(CH_MOVE)
    layer.move_by(37, 21)
    layer.end_gesture()
    sc = scene_of(look, layer, v)
    check("move a sticky", g, sc, prev, 8)
    prev = sc^
    # new words
    var t = pick(layer, TEXT, v)
    layer.set_words(t, "New words, longer than before, to wrap onto more lines than the box had")
    sc = scene_of(look, layer, v)
    check("rewrite a text", g, sc, prev, 8)
    prev = sc^
    # a colour
    layer.set_color(a, 0xFF88CCFF)
    sc = scene_of(look, layer, v)
    check("recolour the sticky", g, sc, prev, 8)
    prev = sc^
    # a delete, undo, redo
    layer.delete(t)
    sc = scene_of(look, layer, v)
    check("delete the text", g, sc, prev, 8)
    prev = sc^
    _ = layer.undo()
    sc = scene_of(look, layer, v)
    check("undo", g, sc, prev, 8)
    prev = sc^
    _ = layer.redo()
    sc = scene_of(look, layer, v)
    check("redo", g, sc, prev, 8)
    prev = sc^
    # a drag: the object lifted out of the tiles while it moves (no tile rastered mid-drag), dropped back on release
    var b = pick(layer, STICKY, v)
    layer.clear_selection()
    layer.select(b)
    layer.begin_gesture(CH_MOVE)
    var lift: List[Int] = [b]
    sc = scene_of(look, layer, v, lift)
    check("drag: lift", g, sc, prev, 8)
    prev = sc^
    var mid = 0
    for f in range(6):
        layer.move_by(19, 7)
        sc = scene_of(look, layer, v, lift)
        check("drag: move " + String(f), g, sc, prev, 0)
        mid += g.tiles.rastered
        prev = sc^
    layer.end_gesture()
    sc = scene_of(look, layer, v)
    check("drag: drop", g, sc, prev, 8)
    prev = sc^
    # a pan and a zoom that settles
    v = DeskView(v.x - 333.3, v.y - 141.7, v.scale)
    sc = scene_of(look, layer, v)
    check("pan", g, sc, prev)
    prev = sc^
    g.tiles.settle_ns = 0
    v = v.zoomed_at(0.62, 720, 450)
    sc = scene_of(look, layer, v)
    check("zoom to 62 %, settled", g, sc, prev)
    prev = sc^
    # (review 2) more edit kinds, each against a direct render
    g.tiles.settle_ns = 120_000_000
    v = DeskView(-300, -200, 1.0)
    sc = scene_of(look, layer, v)
    check("back at 100 %", g, sc, prev)
    prev = sc^
    var c = pick(layer, STICKY, v)
    layer.clear_selection()
    layer.select(c)
    var q = layer.index(c)
    var hp = layer.handle_point(q, H_SE)
    layer.begin_gesture(CH_GESTURE)
    layer.resize_handle(H_SE, hp[0] + 60, hp[1] + 45)
    layer.end_gesture()
    sc = scene_of(look, layer, v)
    check("resize a sticky", g, sc, prev, 8)
    prev = sc^
    layer.bring_to_front()
    sc = scene_of(look, layer, v)
    check("bring it to the front", g, sc, prev, 8)
    prev = sc^
    var st = Stroke(3, 0xFF203040)
    for k in range(40):
        st.add(400 + Float64(k) * 9, 300 + Float64(k % 7) * 11, 0.5)
    var ink = layer.add_ink(st)
    sc = scene_of(look, layer, v)
    check("ink added", g, sc, prev, 8)
    prev = sc^
    layer.delete(ink)
    sc = scene_of(look, layer, v)
    check("ink erased", g, sc, prev, 8)
    prev = sc^
    var moved_end = -1
    for ref o in layer.objs:  # (a connector with an end in the window: that end moves, the line re-routes)
        if o.kind == CONNECTOR and layer.has(o.from_id):
            var f = layer.objs[layer.index(o.from_id)].copy()
            var sc0 = v.to_screen(f.x, f.y)
            if sc0[0] > 100 and sc0[0] < 1300 and sc0[1] > 100 and sc0[1] < 800:
                moved_end = o.from_id
                break
    assert_true(moved_end >= 0, "a connector with an end in the window")
    layer.clear_selection()
    layer.select(moved_end)
    layer.begin_gesture(CH_MOVE)
    layer.move_by(-70, 55)
    layer.end_gesture()
    sc = scene_of(look, layer, v)
    check("a connector re-routed by its end moving", g, sc, prev, 12)
    prev = sc^
    layer.set_rotation(c, 0.35)
    sc = scene_of(look, layer, v)
    check("rotate the sticky", g, sc, prev, 8)
    prev = sc^
    g.tiles.settle_ns = 10_000_000_000  # (the zoom never settles: kept tiles drawn scaled, the view growing past them)
    for z in range(3):
        v = v.zoomed_at(0.93, 720, 450)
        sc = scene_of(look, layer, v)
        check("zoom out " + String(z + 1) + " over kept tiles", g, sc, prev)
        prev = sc^
    g.gl.close()
    # (review 2) a progressive open's slices landing over kept tiles: each frame tiled == direct
    var text = String("")
    try:
        var f = open("build/g79/race/note-stress.json", "r")
        text = f.read()
        f.close()
    except:
        print("   (no build/g79/race/note-stress.json: the open-slices case needs M6's race notes; skipped)")
    if text != "":
        var g2 = GPU2D()
        assert_true(g2.start(False), "start")
        var look2 = BoardLook()
        var ob = OpenBoard()
        var v2 = DeskView(-300, -200, 1.0)
        assert_true(ob.open(text, -900, -700, 2300, 1500, 6) == "", "opens progressively")
        var p2 = Scene(0, 0, 1.0)
        var frames = 0
        while True:
            var s2 = scene_of(look2, ob.layer, v2)
            check("open slice " + String(frames), g2, s2, p2)
            p2 = s2^
            frames += 1
            if not ob.step(-900, -700, 2300, 1500, 1500):
                break
        var s3 = scene_of(look2, ob.layer, v2)
        check("open complete", g2, s3, p2)
        g2.gl.close()
        assert_true(frames >= 2, "the open came in over several frames")
    print("boardraster: ok")
