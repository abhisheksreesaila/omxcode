# Goal 79, D-7973: a sticky's shadow layers leave out the middle its opaque sticky covers (Painter.rect_hole, the quad
# shader's hole) and the picture doesn't change: the stress board tiled at 100 % and at 30 %, and an edit's partial
# rasters, with holes against without (BoardLook.shadow_holes). `shadowhole: ok`.
#   pixi run mojo run -I . -I vendor tests/test_shadowhole.mojo
from std.testing import assert_true, assert_equal
from mojoui.scene import Scene, OP_RECT
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.pagedesk import DeskView, BoardLook, BoardTools
from mojoui.notesshell import draw_shadows, draw_lifted
from mojoui.skin import Shadow
from mojoui.canvas import Surface, rgba
from mojoui.scene import SurfacePainter
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


def lifted_frame(holes: Bool, fill: UInt32, tall: Float64) raises -> Tuple[List[UInt32], List[UInt32], Int]:
    """Panels, islands, a round button and a window of every radius on a busy ground (a tile of two colours, so a shadow
    the hole takes too much of shows), lifted through draw_lifted or by the two calls it stands for: on the GL renderer
    and on the CPU painter."""
    var shadows = List[Shadow]()
    shadows.append(Shadow(0, 2, 6, 0, rgba(10, 12, 20, 31)))
    shadows.append(Shadow(0, 24, 60, -12, rgba(10, 12, 20, 66)))
    var ring = List[Shadow]()
    ring.append(Shadow(0, 0, 0, 2, rgba(90, 60, 200, 120)))
    ring.append(Shadow(0, 14, 38, 0, rgba(0, 0, 0, 90)))
    var sc = Scene(W, H, 1.0)
    var px = List[UInt32](length=W * H, fill=0)
    var s = Surface(Int(px.unsafe_ptr()), W, H, 1.0)
    s.still = True
    var sp = SurfacePainter(s^)
    sc.begin_layer("bg")
    sc.fill(0xFFF0F2F5)
    sp.rect(0, 0, W, H, rgba(240, 242, 245), 0)
    for q in range(0, W, 48):
        sc.rect(Float64(q), 0, 24, H, rgba(200, 120, 40, 255), 0)
        sp.rect(Float64(q), 0, 24, Float64(H), rgba(200, 120, 40, 255), 0)
    var cases = [(100.0, 80.0, 760.0, 455.0, 20.0), (960.0, 90.0, 280.0, tall, 20.0), (1340.0, 100.0, 44.0, 44.0, 22.0), (1440.0, 90.0, 104.0, 48.0, 24.0),
                 (200.0, 640.0, 28.0, 28.0, 5.0), (300.0, 620.0, 900.0, 620.0, 20.0), (1300.0, 640.0, 244.0, 42.0, 21.0), (1600.0, 100.0, 56.0, 500.0, 24.0)]
    var holed = 0
    for ref c in cases:
        for pass_ in range(2):
            if pass_ == 0:
                if holes:
                    draw_lifted(sc, c[0], c[1], c[2], c[3], c[4], shadows if c[2] != 44 else ring, fill)
                else:
                    draw_shadows(sc, c[0], c[1], c[2], c[3], c[4], shadows if c[2] != 44 else ring)
                    sc.rect(c[0], c[1], c[2], c[3], fill, c[4])
            else:
                if holes:
                    draw_lifted(sp, c[0], c[1], c[2], c[3], c[4], shadows if c[2] != 44 else ring, fill)
                else:
                    draw_shadows(sp, c[0], c[1], c[2], c[3], c[4], shadows if c[2] != 44 else ring)
                    sp.rect(c[0], c[1], c[2], c[3], fill, c[4])
    for op in range(sc.ops()):
        if Int(sc.kinds[op]) == OP_RECT and sc.nums[op * 6 + 5] > 0:
            holed += 1
    var g = GPU2D()
    assert_true(g.start(False), "start")
    var slot = g.draw(sc, Scene(0, 0, 1.0), 1, W, H)
    var out = List[UInt32](length=W * H, fill=0)
    assert_true(slot >= 0 and g.gl.read(g.gl.tex[slot], W, H, Int(out.unsafe_ptr())), "read")
    g.gl.close()
    return (out^, px^, holed)


def apart(a: List[UInt32], b: List[UInt32]) -> Tuple[Int, Int]:
    var n = 0
    var worst = 0
    for i in range(len(a)):
        for c in range(4):
            var d = abs(Int((a[i] >> UInt32(8 * c)) & 0xFF) - Int((b[i] >> UInt32(8 * c)) & 0xFF))
            if d > 0:
                n += 1
                worst = max(worst, d)
    return (n, worst)


def test_lifted() raises:
    """(D-8008) draw_lifted: an opaque surface's shadows leave out the middle it covers, and the picture is the same on
    both painters, at every radius and size tried; a see-through surface keeps its whole shadow."""
    for tall in [400.0, 700.0]:
        var a = lifted_frame(True, rgba(250, 250, 252), tall)
        var b = lifted_frame(False, rgba(250, 250, 252), tall)
        assert_true(a[2] > 20, "shadows with a hole")
        var gl = apart(a[0], b[0])
        var cpu = apart(a[1], b[1])
        assert_equal(gl[0], 0, "GL: the same picture")
        assert_equal(cpu[0], 0, "CPU: the same picture")
        var t = lifted_frame(True, rgba(250, 250, 252, 200), tall)
        assert_equal(t[2], 0, "a see-through fill: no hole")
        print("   lifted at", tall, ": ", a[2], "holed shadow layers, GL and CPU pixels identical")


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    test_lifted()
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
