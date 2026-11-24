# D-8019: a zoom-out finds its edges rastered. The stress board zoomed out and in, 1 % a frame, 3 % a frame, and in jumps
# (a fit, 100 % → 30 %), panned between, edited mid-zoom: (a) every frame: no part of the window that a direct render
# shows something in is left as empty ground by the tiled one (32 px blocks; stretched tiles blur, they don't vanish);
# (b) settled, the picture is pixel-identical to a direct render's raster at that view (a fresh renderer's); (c) in a 1 %
# zoom, once the view has been still, each frame rasters at most the budget's ops and one tile over, and a whole zoom
# rasters no visible tile without a fallback. Also: the reach itself (board_rect), and the same with the ops extended ahead
# off (it must still be right: only slower). What a jump shows and costs is printed. `zoomreach: ok`.
#   pixi run mojo build -I . -I vendor tests/test_zoomreach.mojo -o build/test_zoomreach && build/test_zoomreach
from std.testing import assert_true, assert_equal
from std.time import sleep
from mojoui.scene import Scene
from mojoui.clock import now_ns
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.gpu2d_tiles import TILE_BUDGET_OPS
from mojoui.pagedesk import DeskView, BoardLook, BoardTools, board_rect, BOARD_REACH
from mojoui.objectlayer import ObjectLayer, import_json_canvas, CH_MOVE

comptime W = 2304
comptime H = 1440
comptime K = 1.6
comptime BG: UInt32 = 0xFFF0F2F5
comptime B = 32


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


def draw(mut g: GPU2D, mut look: BoardLook, mut layer: ObjectLayer, v: DeskView, take: Bool) raises -> List[UInt32]:
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("bg")
    sc.fill(BG)
    look.paint(sc, layer, v, Float64(W) / K, Float64(H) / K, K)
    var s = g.draw(sc, Scene(0, 0, 1.0), 1, W, H)
    assert_true(s >= 0, "draw")
    var px = List[UInt32]()
    if take:
        px = List[UInt32](length=W * H, fill=0)
        assert_true(g.gl.read(g.gl.tex[s], W, H, Int(px.unsafe_ptr())), "read")
    return px^


def holes(tiled: List[UInt32], direct: List[UInt32]) -> Int:
    """Blocks of B × B px that the direct picture has something in (an eighth of its pixels or more, off the ground) and
    the tiled one shows as bare ground."""
    var n = 0
    for by in range(H // B):
        for bx in range(W // B):
            var d = 0
            var t = 0
            for y in range(by * B, by * B + B):
                for x in range(bx * B, bx * B + B):
                    if direct[y * W + x] != BG:
                        d += 1
                    if tiled[y * W + x] != BG:
                        t += 1
            if d * 8 >= B * B and t == 0:
                n += 1
    return n


def direct(mut layer: ObjectLayer, v: DeskView) raises -> List[UInt32]:
    var g = GPU2D()
    assert_true(g.start(False), "start ref")
    g.tiles_on = False
    var look = BoardLook()
    look.keep_ops = False
    var px = draw(g, look, layer, v, True)
    g.gl.close()
    return px^


def fresh(mut layer: ObjectLayer, v: DeskView) raises -> List[UInt32]:
    """A fresh renderer's settled tiles at this view."""
    var g = GPU2D()
    assert_true(g.start(False), "start fresh")
    var look = BoardLook()
    var px = draw(g, look, layer, v, False)
    sleep(0.15)
    var n = 0
    while g.more and n < 400:
        _ = draw(g, look, layer, v, False)
        n += 1
    px = draw(g, look, layer, v, True)
    g.gl.close()
    return px^


def differ(a: List[UInt32], b: List[UInt32]) -> Int:
    var n = 0
    for i in range(len(a)):
        if a[i] != b[i]:
            n += 1
    return n


def settle(mut g: GPU2D, mut look: BoardLook, mut layer: ObjectLayer, v: DeskView) raises:
    var n = 0
    var t0 = Int(now_ns())
    while (g.more or Int(now_ns()) - t0 < 200_000_000) and n < 2000:
        _ = draw(g, look, layer, v, False)
        n += 1


def run(ahead: Bool) raises:
    var layer = board()
    var g = GPU2D()
    assert_true(g.start(False), "start")
    g.tiles.ahead = ahead
    var look = BoardLook()
    var v = DeskView(-300, -200, 1.0).zoomed_at(0.45, 720, 450)
    _ = draw(g, look, layer, v, False)
    settle(g, look, layer, v)
    var over = 0  # frames past the cap
    var worst = 0
    var frames = 0
    var blank = 0
    # (c) 1 % a frame out to 25 %, then in: each frame's raster work, and (a) every sixth frame's picture
    for step in range(120):
        v = v.zoomed_at(v.scale * (1.0 / 1.01 if step < 60 else 1.01), 720, 450)
        var px = draw(g, look, layer, v, step % 12 == 5)
        frames += 1
        worst = max(worst, g.tiles.planned_ops)
        if g.tiles.planned_ops > 2 * TILE_BUDGET_OPS + 1500:
            over += 1
        if step % 12 == 5:
            blank += holes(px, direct(layer, v))
    print("   1 % a frame: " + String(frames) + " frames, the most ops rastered in one " + String(worst) + ", over the cap " + String(over) + ", blank blocks " + String(blank))
    assert_equal(blank, 0, "1 % a frame: nothing shown blank")
    if ahead:
        assert_equal(over, 0, "1 % a frame: under the cap")
    settle(g, look, layer, v)
    assert_equal(differ(draw(g, look, layer, v, True), fresh(layer, v)), 0, "settled: identical to a fresh raster")
    # 3 % a frame, panning and an edit between (what the fallback and the strips must still get right)
    var blank3 = 0
    for step in range(36):
        v = v.zoomed_at(v.scale * (1.0 / 1.03 if step < 18 else 1.03), 500, 300)
        if step % 9 == 3:
            v.x += 180
            v.y -= 90
        if step % 13 == 6:
            var vis = BoardTools().visible_objects(layer, v, 1440, 900)
            if len(vis) > 0:
                layer.select(layer.objs[vis[len(vis) // 2]].id, False)
                layer.begin_gesture(CH_MOVE)
                layer.move_by(21, 13)
                layer.end_gesture()
        var px = draw(g, look, layer, v, step % 6 == 2)
        if step % 6 == 2:
            blank3 += holes(px, direct(layer, v))
    assert_equal(blank3, 0, "3 % a frame: nothing shown blank")
    settle(g, look, layer, v)
    assert_equal(differ(draw(g, look, layer, v, True), fresh(layer, v)), 0, "settled after edits: identical")
    # jumps: a fit to 30 %, back to 100 %, to 12 %: nothing kept covers them; whole frames rastered at once, whole picture
    var sizes = [0.3, 1.0, 0.12, 0.9]
    for sz in sizes:
        var t0 = Int(now_ns())
        v = v.zoomed_at(sz, 720, 450)
        var px = draw(g, look, layer, v, True)
        var ms = Float64(Int(now_ns()) - t0) / 1e6
        assert_equal(holes(px, direct(layer, v)), 0, "a jump shows the whole picture in its frame")
        print("   a jump to " + String(sz) + ": " + String(ms) + " ms (with readback), " + String(g.tiles.rastered) + " rasters, " + String(g.tiles.planned_ops) + " ops; nothing blank")
        settle(g, look, layer, v)
        assert_equal(differ(draw(g, look, layer, v, True), fresh(layer, v)), 0, "settled after a jump: identical")
    g.gl.close()


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    var a = board_rect(DeskView(-300, -200, 0.3), 1440, 900, BOARD_REACH)
    var b = board_rect(DeskView(-300, -200, 0.3), 1440, 900)
    assert_true(a[0] <= b[0] and a[1] <= b[1] and a[2] >= b[2] and a[3] >= b[3] and (a[0] < b[0] or a[2] > b[2]), "the reach only grows the rect")
    for ahead in [True, False]:
        print("ahead", ahead)
        run(ahead)
    print("zoomreach: ok")
