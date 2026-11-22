# Goal 79, D-7966: the GL path sets a run's state only when it changed (vertex array, buffer, attributes, the replace
# flag, the atlas) and, with GL_ARB_base_instance, points the attributes once per buffer and names each run's first
# instance. The same frames (the stress board: tiled, then an edit's partial rasters, then the board drawn directly as
# a plain layer) drawn by a renderer with it and one without (MOJOUI_GL_CACHE=0's path) are pixel-identical, with far
# fewer GL calls. `glstate: ok`.
#   pixi run mojo run -I . -I vendor tests/test_glstate.mojo
from std.testing import assert_true, assert_equal
from mojoui.scene import Scene
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


def frame(mut g: GPU2D, sc: Scene, prev: Scene) raises -> List[UInt32]:
    var s = g.draw(sc, prev, 1, W, H)
    assert_true(s >= 0, "draw: " + g.gl.why)
    var px = List[UInt32](length=W * H, fill=0)
    assert_true(g.gl.read(g.gl.tex[s], W, H, Int(px.unsafe_ptr())), "read")
    return px^


def calls(g: GPU2D) -> Int:
    """The last frame's GL calls (the entry points and extension calls; not the byte counter)."""
    var t = 0
    for q in range(len(g.gl.counts)):
        if q != 74:  # (F_COUNT + C_BYTES)
            t += g.gl.counts[q]
    return t


def differ(a: List[UInt32], b: List[UInt32]) -> Int:
    var n = 0
    for i in range(len(a)):
        if a[i] != b[i]:
            n += 1
    return n


def scene_of(mut look: BoardLook, mut layer: ObjectLayer, v: DeskView, tiled: Bool) -> Scene:
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("bg")
    sc.fill(0xFFF0F2F5)
    if tiled:
        look.paint(sc, layer, v, 1440, 900, K)
    else:  # (the same items as a plain layer: the composite path's runs, not tiles)
        sc.begin_layer("plain")
        sc.layer_transform(v.x * K, v.y * K, v.scale * K)
        for i in layer.query(-400, -300, 1400, 900):
            look.paint_obj(sc, layer, i)
    return sc^


def run(name: String, cache: Bool, base: Bool, mut layer: ObjectLayer, merge: Bool = False) raises -> Tuple[List[List[UInt32]], Int]:
    var g = GPU2D()
    assert_true(g.start(False), "start")
    g.tile_merge = merge
    g.gl.state_cache = cache
    if not base:
        g.gl.base_instance = 0
    g.gl.counting = True
    var look = BoardLook()
    var v = DeskView(-300, -200, 1.0)
    var out = List[List[UInt32]]()
    var total = 0
    var prev = Scene(0, 0, 1.0)
    var steps = ["tiled", "tiled again", "after an edit", "plain layer"]
    for q in range(4):
        if q == 2:
            var vis = BoardTools().visible_objects(layer, v, 1440, 900)
            layer.select(layer.objs[vis[len(vis) // 2]].id, False)
            layer.begin_gesture(CH_MOVE)
            layer.move_by(23, -17)
            layer.end_gesture()
        var sc = scene_of(look, layer, v, q < 3)
        out.append(frame(g, sc, prev))
        while g.more:
            _ = frame(g, sc, sc)
        total += calls(g)
        prev = sc^
    _ = layer.undo()
    print("   " + name + ": " + String(total) + " GL calls in 4 frames (base instance " + ("on" if g.gl.base_instance != 0 else "off") + ")")
    g.gl.close()
    return (out^, total)


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    var layer = board()
    print("   board:", len(layer.objs), "objects")
    var off = run("per-run state (as before)", False, False, layer)
    var on = run("cached state", True, True, layer)
    var nobase = run("cached state, no base instance", True, False, layer)
    var merged = run("cached state, tiles' runs regrouped", True, True, layer, True)
    for q in range(4):
        var d = differ(off[0][q], on[0][q])
        var d2 = differ(off[0][q], nobase[0][q])
        print("   frame " + String(q) + ": " + String(d) + " / " + String(d2) + " pixels differ")
        assert_equal(d, 0)
        assert_equal(d2, 0)
        var d3 = differ(off[0][q], merged[0][q])
        print("   frame " + String(q) + " with tiles' runs regrouped: " + String(d3) + " pixels differ")
        assert_equal(d3, 0)
    assert_true(on[1] < off[1], "fewer GL calls")
    print("glstate: ok · calls " + String(off[1]) + " → " + String(on[1]) + " (no base instance " + String(nobase[1]) + "; tiles' runs regrouped " + String(merged[1]) + ")")
