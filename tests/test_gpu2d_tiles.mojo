# Raster tiles (goal 79, D-7940, mojoui.gpu2d_tiles + the GL backend): a big board in a layer that said layer_tiles,
# drawn by GPU2D from kept tiles, against the same scene drawn directly (tiles off): the readback must agree within
# M2's fill bound (no channel more than 4 levels off; mean ≤ 0.1) after the first frame, a pan, an edit with damage (only
# the tiles it meets are rastered again), an edit without damage (every tile), and a zoom once it settles (text
# rasterized again at the new zoom, never left scaled). Then the frame times of pans and zoom steps on boards of 600 and
# 5,296 objects, tiled and direct (CPU + GPU, glFinish-timed). Prints `gpu2d tiles: ok`.
#   pixi run mojo run -I . tests/test_gpu2d_tiles.mojo
from std.testing import assert_true
from std.time import perf_counter_ns
from mojoui.scene import Scene, Painter
from mojoui.fonttext import TextStyle
from mojoui.canvas import rgba
from mojoui.gpu2d_gl import GPU2D, headless_gl33
from mojoui.gpu2d_tiles import TILE
from tests.test_gpu2d import Rng

comptime W = 2304  # 1440 × 900 at 1.6
comptime H = 1440


def corner_poly(x: Float64, y: Float64, w: Float64, h: Float64) -> List[Float64]:
    var out: List[Float64] = [x + 4, y, x + w - 4, y, x + w, y + 4, x + w, y + h - 24, x + w - 24, y + h, x + 4, y + h, x, y + h - 4, x, y + 4]
    return out^


def board[P: Painter](mut p: P, n: Int, tx: Float64, ty: Float64, k: Float64, moved: Int = -1, mdx: Float64 = 0, version: Int = 1,
                      tiles: Bool = True, since: Int = -1, dmg: List[Float64] = List[Float64]()):
    """A page with n objects (stickies with a shadow and words, text boxes, connectors) in one tiled layer."""
    p.begin_layer("bg")
    p.fill(rgba(242, 239, 232))
    p.begin_layer("board")
    p.layer_version(version)
    p.layer_transform(tx, ty, k)
    if tiles:
        p.layer_tiles(-1e9, -1e9, 1e9, 1e9)
        for d in range(len(dmg) // 4):
            p.layer_damage(since, dmg[4 * d], dmg[4 * d + 1], dmg[4 * d + 2], dmg[4 * d + 3])
    var rng = Rng(79)
    var cols = Int(Float64(n) ** 0.5 * 1.6) + 1
    var serif = TextStyle("Source Serif 4", 400, False, 16)
    serif.exact = True
    var sans = TextStyle("Geist", 500, False, 14)
    sans.exact = True
    var px = 0.0
    var py = 0.0
    for i in range(n):
        var x = Float64(i % cols) * 230 + rng.real(0, 40)
        var y = Float64(i // cols) * 200 + rng.real(0, 40)
        if i == moved:
            x += mdx
        var kind = i % 3
        if kind == 0:
            p.rect(x, y + 9, 180, 160, rgba(0, 0, 0, 30), 12)
            p.polygon(corner_poly(x, y, 180, 160), rgba(255, 233, 150))
            p.run(sans, "Sticky " + String(i), x + 22, y + 40, rgba(60, 50, 30), 0)
            p.run(sans, "a few words here", x + 22, y + 60, rgba(60, 50, 30), 0)
        elif kind == 1:
            p.run(serif, "Text box number " + String(i), x, y + 20, rgba(31, 27, 22), 0)
            p.run(serif, "with a second line, ẞ fé 中", x, y + 40, rgba(31, 27, 22), 0)
        else:
            p.line(px, py, x, y, 2, rgba(51, 34, 34))
            p.circle(x, y, 5, rgba(51, 34, 34))
        px = x + 90
        py = y + 80


def picture(mut g: GPU2D, sc: Scene, prev: Scene) raises -> List[UInt32]:
    var s = g.draw(sc, prev, 1, sc.w, sc.h)
    assert_true(s >= 0, "draw: " + g.gl.why)
    var px = List[UInt32](length=sc.w * sc.h, fill=0)
    assert_true(g.gl.read(g.gl.tex[s], sc.w, sc.h, Int(px.unsafe_ptr())), "read back")
    return px^


def scene_of(n: Int, tx: Float64, ty: Float64, k: Float64, moved: Int = -1, mdx: Float64 = 0, version: Int = 1, since: Int = -1,
             dmg: List[Float64] = List[Float64]()) -> Scene:
    var sc = Scene(W, H, 1.0)
    board(sc, n, tx, ty, k, moved, mdx, version, True, since, dmg)
    return sc^


def check(name: String, want: List[UInt32], got: List[UInt32]) raises:
    var total = 0
    var worst = 0
    var off = 0
    for i in range(len(want)):
        var w0 = 0
        for c in range(3):
            var d = abs(Int((want[i] >> UInt32(8 * c)) & 0xFF) - Int((got[i] >> UInt32(8 * c)) & 0xFF))
            total += d
            w0 = max(w0, d)
        worst = max(worst, w0)
        if w0 > 0:
            off += 1
    var mean = Float64(total) / Float64(3 * len(want))
    print("  ", name, ": tiled vs direct: mean", round(mean, 4), "levels, worst", worst, "levels,", off, "pixels differ at all")
    assert_true(worst <= 4 and mean <= 0.1, name + ": the tiled frame differs from a direct render")


def direct(sc: Scene) raises -> List[UInt32]:
    var g = GPU2D()
    assert_true(g.start(False), "GPU2D.start: " + g.gl.why)
    g.tiles_on = False
    var empty = Scene(0, 0, 1.0)
    var px = picture(g, sc, empty)
    g.gl.close()
    return px^


def settle(mut g: GPU2D, sc: Scene, prev: Scene) raises -> List[UInt32]:
    """Frames of the same scene until the renderer wants no more (tiles all rastered); the last picture."""
    var px = picture(g, sc, prev)
    var frames = 1
    while g.more and frames < 60:
        px = picture(g, sc, sc)
        frames += 1
    assert_true(not g.more, "the tiles never settled")
    return px^


def frame_ms(mut g: GPU2D, sc: Scene, prev: Scene) raises -> Float64:
    var t0 = perf_counter_ns()
    var s = g.draw(sc, prev, 1, sc.w, sc.h)
    assert_true(s >= 0, "draw")
    g.gl.finish()
    g.gl.busy[s] = 0
    return Float64(Int(perf_counter_ns() - t0)) / 1e6


def timing(n: Int, label: String) raises:
    """Pans (7 px a frame, 60 frames) and zoom steps (1.01×, 30 frames) at a board-wide zoom: tiled and direct."""
    var k0 = 0.48
    for mode in range(2):
        var g = GPU2D()
        assert_true(g.start(False), "GPU2D.start")
        g.tiles_on = mode == 0
        var prev = scene_of(n, 40, 30, k0)
        var first = prev.copy()
        _ = settle(g, first, Scene(0, 0, 1.0))
        var pans = List[Float64]()
        for f in range(60):
            var sc = scene_of(n, 40 + Float64(f % 20) * 7, 30 + Float64(f % 20) * 4, k0)
            pans.append(frame_ms(g, sc, prev))
            prev = sc^
        var zooms = List[Float64]()
        var k = k0
        for f in range(30):
            k *= 1.01
            var sc = scene_of(n, 40 - Float64(f) * 11, 30 - Float64(f) * 7, k)
            zooms.append(frame_ms(g, sc, prev))
            prev = sc^
        sort(pans)
        sort(zooms)
        print("  ", label, "tiled" if mode == 0 else "direct", ": pan p95", round(pans[56], 2), "max", round(pans[59], 2), "ms; zoom step p95",
              round(zooms[28], 2), "max", round(zooms[29], 2), "ms (CPU + GPU, glFinish)")
        if mode == 0 and n > 1000:
            assert_true(pans[56] <= 8.3 and zooms[28] <= 8.3, label + ": tiled pans or zoom steps not within 8.3 ms")
        g.gl.close()


def main() raises:
    var ctx = headless_gl33()
    assert_true(ctx != 0, "a headless GL 3.3 core context")
    var n = 600
    var k = 1.6
    var g = GPU2D()
    assert_true(g.start(False), "GPU2D.start: " + g.gl.why)
    var empty = Scene(0, 0, 1.0)
    # 1. first frame
    var a = scene_of(n, 33.4, 21.6, k)
    var got = settle(g, a, empty)
    print("   first frame: tiles rastered", g.tiles.rastered, ", drawn", g.tiles.drawn)
    check("first frame", direct(a), got)
    # 2. a pan (fractional: snapped to whole px), only tiles newly in view rastered
    var b = scene_of(n, 33.4 - 300.7, 21.6 - 90.2, k)
    var before = g.tiles.rastered
    var gb = picture(g, b, a)
    var pan_r = g.tiles.rastered
    _ = before
    print("   pan by (-300.7, -90.2): tiles rastered", pan_r, "(must ones), drawn", g.tiles.drawn)
    check("pan", direct(b), gb)
    _ = settle(g, b, b)
    # 3. an edit with damage: object 4 moved 60 units right; damage its box before and after
    var d: List[Float64] = []
    var c = scene_of(n, 33.4 - 300.7, 21.6 - 90.2, k, 4, 60, 2, 1, d)
    var probe = Scene(10, 10, 1.0)
    _ = probe
    # object 4's box (sticky? 4 % 3 = 1: a text box); its old and new places, generously
    var cols = Int(Float64(n) ** 0.5 * 1.6) + 1
    var ox = Float64(4 % cols) * 230
    var oy = Float64(4 // cols) * 200
    var dm: List[Float64] = [ox - 10, oy - 10, ox + 400, oy + 60]
    c = scene_of(n, 33.4 - 300.7, 21.6 - 90.2, k, 4, 60, 2, 1, dm)
    var gc = picture(g, c, b)
    print("   edit with damage: tiles freed", g.tiles.damaged, ", rastered", g.tiles.rastered)
    assert_true(g.tiles.damaged >= 1 and g.tiles.damaged <= 6, "damage freed the wrong tiles")
    check("edit with damage", direct(c), gc)
    # 4. an edit without damage: every tile
    var e = scene_of(n, 33.4 - 300.7, 21.6 - 90.2, k, 4, 120, 3)
    var visible = g.tiles.drawn
    var ge = picture(g, e, c)
    print("   edit without damage: tiles rastered", g.tiles.rastered, "of", visible, "drawn before")
    assert_true(g.tiles.rastered >= visible, "an edit without damage kept tiles")
    check("edit without damage", direct(e), ge)
    _ = settle(g, e, e)
    # 5. a zoom: scaled while moving, then rasterized again at the new zoom
    g.tiles.settle_ns = 1_000_000_000_000  # (held: the zoom never settles by time here)
    var z = scene_of(n, 33.4 - 300.7, 21.6 - 90.2, k * 1.05, 4, 120, 3)
    _ = picture(g, z, e)
    print("   zoom 1.05× (moving): tiles rastered", g.tiles.rastered, ", drawn", g.tiles.drawn, ", more", g.more)
    assert_true(g.more, "a moving zoom should leave the tiles to settle")
    g.tiles.settle_ns = 0
    var gz = settle(g, z, z)
    check("zoom settled (text rasterized at 1.05×)", direct(z), gz)
    g.gl.close()
    # 6. times
    timing(600, "600 objects")
    timing(5296, "5,296 objects")
    print("gpu2d tiles: ok")
