# D-8022: a raster tile's batches leave out the boxes, capsules and glyphs outside the part being rastered, and nothing
# changes: the stress board (and one of long strokes, diagonal lines, emoji and paragraphs) through moves, undos, pans,
# 1 % and 7 % zooms and a lift, frame by frame pixel-identical with and without, at whole and partial rasters; and fewer
# instances are built. `tilecull: ok`.
#   pixi run mojo build -I . -I vendor tests/test_tilecull.mojo -o build/test_tilecull && build/test_tilecull
from std.testing import assert_true, assert_equal
from std.time import sleep
from mojoui.scene import Scene
from mojoui.canvas import rgba
from mojoui.gpu2d import QUAD_FLOATS, GLYPH_FLOATS
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.pagedesk import DeskView, BoardLook, BoardTools
from mojoui.objectlayer import ObjectLayer, import_json_canvas, CH_MOVE

comptime W = 2304
comptime H = 1440
comptime K = 1.6


def stress() -> ObjectLayer:
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


def odd() raises -> ObjectLayer:
    """Long words, emoji and other scripts, and connectors crossing the whole board every way."""
    var l = ObjectLayer()
    var ids = List[Int]()
    for i in range(160):
        var words = String("Sticky ") + String(i) + " with a long paragraph 📚 漢字 नमस्ते that wraps over several lines, fi ffl"
        ids.append(l.add_sticky(Float64((i * 733) % 4200), Float64((i * 397) % 3000), 90 + Float64(i % 5) * 60, words))
        _ = l.add_text(Float64((i * 911) % 4200), Float64((i * 577) % 3000), 340, 60, words)
    for i in range(0, 150, 2):
        _ = l.add_connector(ids[i], ids[(i * 7 + 31) % 160])
    return l^


def frame(mut g: GPU2D, mut look: BoardLook, mut layer: ObjectLayer, v: DeskView, lift: List[Int]) raises -> List[UInt32]:
    var sc = Scene(W, H, 1.0)
    sc.begin_layer("bg")
    sc.fill(0xFFF0F2F5)
    look.paint(sc, layer, v, 1440, 900, K, lift)
    var s = g.draw(sc, Scene(0, 0, 1.0), 1, W, H)
    assert_true(s >= 0, "draw")
    var px = List[UInt32](length=W * H, fill=0)
    assert_true(g.gl.read(g.gl.tex[s], W, H, Int(px.unsafe_ptr())), "read")
    return px^


def built(g: GPU2D) -> Int:
    var n = 0
    for r in range(min(g.tiles.rastered, len(g.tile_frames))):
        n += len(g.tile_frames[r].quads) // QUAD_FLOATS + len(g.tile_frames[r].glyphs) // GLYPH_FLOATS
    return n


def run(var layer: ObjectLayer, name: String) raises:
    var a = GPU2D()
    var b = GPU2D()
    assert_true(a.start(False) and b.start(False), "start")
    a.tiles.cull = True
    b.tiles.cull = False
    var la = BoardLook()
    var lb = BoardLook()
    var v = DeskView(-300, -200, 1.0)
    var none = List[Int]()
    var na = 0
    var nb = 0
    var seed = 12345
    var rasters = 0
    for step in range(70):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        var lift = List[Int]()
        var kind = (seed >> 8) % 7
        if kind <= 2:
            var vis = BoardTools().visible_objects(layer, v, 1440, 900)
            if len(vis) > 0:
                layer.select(layer.objs[vis[(seed >> 12) % len(vis)]].id, False)
                layer.begin_gesture(CH_MOVE)
                layer.move_by(6 + Float64((seed >> 5) % 60), 4 - Float64((seed >> 7) % 40))
                layer.end_gesture()
        elif kind == 3:
            _ = layer.undo()
        elif kind == 4:
            v.x += Float64((seed >> 6) % 500 - 250)
            v.y += Float64((seed >> 9) % 300 - 150)
        elif kind == 5:
            v = v.zoomed_at(max(0.2, min(2.2, v.scale * (1.01 if step % 2 == 0 else 1.0 / 1.07))), 720, 450)
            if step % 3 == 0:
                sleep(0.13)  # (settles: tiles at the new zoom)
        else:
            var vis = BoardTools().visible_objects(layer, v, 1440, 900)
            for q in range(min(5, len(vis))):
                lift.append(layer.objs[vis[(q * 3) % len(vis)]].id)
        var pa = frame(a, la, layer, v, lift)
        var pb = frame(b, lb, layer, v, lift)
        rasters += a.tiles.rastered
        assert_equal(a.tiles.rastered, b.tiles.rastered)
        na += built(a)
        nb += built(b)
        var d = 0
        for i in range(W * H):
            if pa[i] != pb[i]:
                d += 1
        assert_equal(d, 0, name + " step " + String(step) + ": pixel-identical")
    assert_true(rasters > 60, "tiles were rastered: " + String(rasters))
    assert_true(na < nb, "fewer instances built")
    print("   " + name + ": 70 steps, " + String(rasters) + " rasters, pixel-identical; instances " + String(nb) + " -> " + String(na))
    a.gl.close()
    b.gl.close()


def main() raises:
    assert_true(headless_gl33() != 0, "a headless GL context")
    run(stress(), "stress")
    run(odd(), "words, emoji, crossing connectors")
    print("tilecull: ok")
