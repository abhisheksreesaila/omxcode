# Goal 79, D-7973: a sticky's shadow layers leave out the middle its opaque sticky covers (Painter.rect_hole, the quad
# shader's hole) and the picture doesn't change: the stress board tiled at 100 % and at 30 %, and an edit's partial
# rasters, with holes against without (BoardLook.shadow_holes). `shadowhole: ok`.
#   pixi run mojo run -I . -I vendor tests/test_shadowhole.mojo
from std.testing import assert_true, assert_equal
from mojoui.scene import Scene, OP_RECT
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
            _ = l.add_sticky(Float64(i % 40) * 120, Float64(i // 40) * 110, 90, "Sticky " + String(i))
        return l^


def frames(mut layer: ObjectLayer, holes: Bool) raises -> Tuple[List[List[UInt32]], Int]:
    var g = GPU2D()
    assert_true(g.start(False), "start")
    var look = BoardLook()
    look.shadow_holes = holes
    var out = List[List[UInt32]]()
    var prev = Scene(0, 0, 1.0)
    var holed = 0
    var views = [DeskView(-300, -200, 1.0), DeskView(-300, -200, 1.0), DeskView(-100, -60, 0.3)]
    for q in range(3):
        if q == 1:
            var vis = BoardTools().visible_objects(layer, views[0], 1440, 900)
            layer.select(layer.objs[vis[len(vis) // 2]].id, False)
            layer.begin_gesture(CH_MOVE)
            layer.move_by(6, 4)
            layer.end_gesture()
        var sc = Scene(W, H, 1.0)
        sc.begin_layer("bg")
        sc.fill(0xFFF0F2F5)
        look.paint(sc, layer, views[q], 1440, 900, K)
        for op in range(sc.ops()):
            if Int(sc.kinds[op]) == OP_RECT and sc.nums[op * 6 + 5] > 0:
                holed += 1
        var s = g.draw(sc, prev, 1, W, H)
        while g.more:
            s = g.draw(sc, sc, 1, W, H)
        var px = List[UInt32](length=W * H, fill=0)
        assert_true(s >= 0 and g.gl.read(g.gl.tex[s], W, H, Int(px.unsafe_ptr())), "read")
        out.append(px^)
        prev = sc^
    _ = layer.undo()
    g.gl.close()
    return (out^, holed)


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    var layer = board()
    var whole = frames(layer, False)
    var holes = frames(layer, True)
    assert_equal(whole[1], 0)
    assert_true(holes[1] > 0, "shadow layers with holes were drawn")
    var names = ["tiled at 100 %", "an edit's partial rasters", "tiled at 30 %"]
    for q in range(3):
        var d = 0
        var worst = 0
        var at = -1
        for i in range(len(whole[0][q])):
            if whole[0][q][i] != holes[0][q][i]:
                d += 1
                for sh in range(4):
                    var dv = abs(Int((whole[0][q][i] >> UInt32(8 * sh)) & 0xFF) - Int((holes[0][q][i] >> UInt32(8 * sh)) & 0xFF))
                    if dv > worst:
                        worst = dv
                        at = i
        print("   " + names[q] + ": " + String(d) + " pixels differ" + (", worst " + String(worst) + " levels at (" + String(at % W) + ", " + String(at // W) + ")" if at >= 0 else String(""))
              + (" " + hex(Int(whole[0][q][at])) + " vs " + hex(Int(holes[0][q][at])) if at >= 0 else ""))
        assert_equal(d, 0)
    print("shadowhole: ok · " + String(holes[1]) + " shadow layers left their middle out")
