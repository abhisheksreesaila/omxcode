# Goal 79, D-7972: quads and glyphs whose box is first cut to their clip and to the scissor (a partial raster's part, the
# tile, the frame) before the one triangle holding it is built give the same pixels as the whole box's triangle: the stress board tiled (first frame, an edit's partial rasters) and drawn directly as a plain layer, a
# renderer with the old shaders (MOJOUI_GL_ONE_TRI=1) against one with the new. `boxverts: ok`.
#   pixi run mojo run -I . -I vendor tests/test_boxverts.mojo
from std.testing import assert_true, assert_equal
from std.os import setenv, unsetenv
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
            if i % 2 == 0:
                _ = l.add_text(Float64(i % 40) * 120, Float64(i // 40) * 110, 110, 40, "Text " + String(i))
            else:
                _ = l.add_sticky(Float64(i % 40) * 120, Float64(i // 40) * 110, 90, "Sticky " + String(i))
        return l^


def frames(mut layer: ObjectLayer) raises -> List[List[UInt32]]:
    var g = GPU2D()
    assert_true(g.start(False), "start")
    var look = BoardLook()
    var out = List[List[UInt32]]()
    var prev = Scene(0, 0, 1.0)
    var views = [DeskView(-300, -200, 1.0), DeskView(-300, -200, 1.0), DeskView(-300, -200, 0.45), DeskView(-300, -200, 1.0)]
    for q in range(4):
        if q == 1:
            var vis = BoardTools().visible_objects(layer, views[0], 1440, 900)
            layer.select(layer.objs[vis[len(vis) // 2]].id, False)
            layer.begin_gesture(CH_MOVE)
            layer.move_by(6, 4)
            layer.end_gesture()
        var sc = Scene(W, H, 1.0)
        sc.begin_layer("bg")
        sc.fill(0xFFF0F2F5)
        if q < 3:
            look.paint(sc, layer, views[q], 1440, 900, K)
        else:  # (the same items as a plain layer, clipped: quads and glyphs cut to a clip)
            sc.begin_layer("plain")
            sc.layer_transform(views[q].x * K, views[q].y * K, K)
            sc.push_clip(100, 80, 700, 400)
            for i in layer.query(-400, -300, 1400, 900):
                look.paint_obj(sc, layer, i)
            sc.pop_clip()
        var s = g.draw(sc, prev, 1, W, H)
        while g.more:
            s = g.draw(sc, sc, 1, W, H)
        var px = List[UInt32](length=W * H, fill=0)
        assert_true(s >= 0 and g.gl.read(g.gl.tex[s], W, H, Int(px.unsafe_ptr())), "read")
        out.append(px^)
        prev = sc^
    _ = layer.undo()
    g.gl.close()
    return out^


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    var layer = board()
    _ = setenv("MOJOUI_GL_ONE_TRI", "1", True)
    var old = frames(layer)
    _ = unsetenv("MOJOUI_GL_ONE_TRI")
    var new = frames(layer)
    var names = ["tiled", "an edit's partial rasters", "zoomed out (settled)", "a plain clipped layer"]
    for q in range(4):
        var d = 0
        for i in range(len(old[q])):
            if old[q][i] != new[q][i]:
                d += 1
        print("   " + names[q] + ": " + String(d) + " pixels differ")
        assert_equal(d, 0)
    print("boxverts: ok")
