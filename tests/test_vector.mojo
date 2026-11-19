# mojoui.vector and mojoui.charms (goal 77 M7e): SVG paths read right (Lucide's compact numbers, arcs, relative moves), an
# icon drawn on a canvas lands inside its square, every tile icon and every charm draws, colours come from the palette
# (light and night differ), a swinging charm moves with the clock and rests when still.
#   pixi run mojo run --disable-warnings -I . tests/test_vector.mojo     (a contact sheet: build/g77/vector-sheet.png)
# Prints one "<name>: ok" line per check, then "vector: ok".
from std.testing import assert_equal, assert_true, assert_false
from mojoui.canvas import Surface
from mojoui.vector import parse_svg, draw_vector, draw_icon, Vector
from mojoui.charms import charm_names, draw_charm, charm_angle, charm_colours, charm_moves, palette_family
from mojoui.livetiles import tile_icon
from mojoui.png import encode_png
from mojoui.text import Font
from mojoui.theme import rgba
from themes.omxqua import counter_palette


def painted(px: List[UInt32], w: Int, x0: Int, y0: Int, x1: Int, y1: Int, bg: UInt32) -> Int:
    var n = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            if px[y * w + x] != bg:
                n += 1
    return n


def test_paths() raises:
    var v = parse_svg("<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2'><path d='M7.5 7a1 1 0 0 1 0-5A4.8 8 0 0 1 12 7' /><rect x='3' y='7' width='18' height='4' rx='1' /><path d='m4.93 4.93 1.41 1.41' /></svg>")
    assert_equal(len(v.shapes), 3)
    assert_equal(v.w, 24.0)
    var p = v.shapes[0].pts.copy()
    assert_true(abs(p[0] - 7.5) < 1e-9 and abs(p[1] - 7.0) < 1e-9, "M")
    # the first arc ends 5 up (relative 0,-5): (7.5, 2)
    var found = False
    for i in range(len(p) // 2):
        if abs(p[2 * i] - 7.5) < 1e-6 and abs(p[2 * i + 1] - 2.0) < 1e-6:
            found = True
    assert_true(found, "a relative arc lands at (7.5, 2)")
    assert_true(abs(p[len(p) - 2] - 12.0) < 1e-6 and abs(p[len(p) - 1] - 7.0) < 1e-6, "the absolute arc ends at (12, 7)")
    assert_true(v.shapes[1].closed[0], "a rect is closed")
    var q = v.shapes[2].pts.copy()
    assert_true(abs(q[2] - 6.34) < 1e-9 and abs(q[3] - 6.34) < 1e-9, "a relative line after a relative move")
    print("paths: ok")


def test_icons(mut sheet: List[UInt32], sw: Int) raises:
    var names: List[String] = ["car", "todo", "cal", "cam", "gift", "cloud", "cloud-rain", "timer", "plane", "home", "backpack", "trophy",
                               "utensils", "image", "map-pin", "party-popper"]
    var bg = rgba(255, 255, 255)
    for i in range(len(names)):
        var x = 10 + i * 40
        var px = List[UInt32](length=48 * 48, fill=bg)
        var s = Surface(Int(px.unsafe_ptr()), 48, 48, 1.0)
        assert_true(draw_icon(s, tile_icon(names[i]), 6.0, 6.0, 36.0, rgba(20, 20, 30)), names[i] + " is a Lucide icon")
        var inside = painted(px, 48, 6, 6, 42, 42, bg)
        var all = painted(px, 48, 0, 0, 48, 48, bg)
        assert_true(inside > 60, names[i] + ": drew " + String(inside) + " pixels")
        assert_true(all - inside <= all // 20, names[i] + ": stays in its square")
        for y in range(48):
            for xx in range(48):
                if x + xx < sw:
                    sheet[(10 + y) * sw + x + xx] = px[y * 48 + xx]
        _ = len(px)
    var s2 = List[UInt32](length=16, fill=bg)
    var surf = Surface(Int(s2.unsafe_ptr()), 4, 4, 1.0)
    assert_false(draw_icon(surf, "no-such-icon", 0, 0, 4, bg))
    _ = len(s2)
    print("icons: ok")


def test_charms(mut sheet: List[UInt32], sw: Int) raises:
    var font = Font()
    var names = charm_names()
    for dark in range(2):
        var p = counter_palette(dark == 1)
        var y0 = 80 + dark * 170
        for i in range(len(names)):
            var x0 = 10 + i * 150
            # a card's top-right corner at (x0 + 140, y0 + 60) on the card colour
            for y in range(y0, y0 + 160):
                for x in range(x0, x0 + 145):
                    sheet[y * sw + x] = p.card if y >= y0 + 60 else p.page
            var s = Surface(Int(sheet.unsafe_ptr()), sw, 430, 1.0)
            var before = sheet.copy()
            assert_true(draw_charm(s, names[i], Float64(x0 + 140), Float64(y0 + 60), 1.0, p, font, 700), names[i])
            var n = 0
            for y in range(y0, y0 + 160):
                for x in range(x0, x0 + 145):
                    if sheet[y * sw + x] != before[y * sw + x]:
                        n += 1
            assert_true(n > 150, names[i] + ": drew " + String(n) + " pixels")
        # colours from the palette: night differs from day
    var day = charm_colours("bag", counter_palette(False))
    var night = charm_colours("bag", counter_palette(True))
    assert_true(day[2] != night[2], "the bag's blue follows the palette")
    assert_equal(day[2], palette_family(counter_palette(False), 205.0))
    var any_s = Surface(Int(sheet.unsafe_ptr()), sw, 430, 1.0)
    assert_false(draw_charm(any_s, "nope", 0, 0, 1.0, counter_palette(False), font))
    print("charms draw from the palette: ok")


def test_motion() raises:
    assert_true(charm_moves("bag") and charm_moves("tag") and charm_moves("pennant"))
    assert_false(charm_moves("hat") or charm_moves("umbrella") or charm_moves("turkey"))
    var lo = 1e9
    var hi = -1e9
    for t in range(0, 7000, 50):
        var a = charm_angle("bag", t, False)
        lo = min(lo, a)
        hi = max(hi, a)
    assert_true(abs(lo + 7.0) < 0.2 and abs(hi - 7.0) < 0.2, "the bag swings -7..7")
    var f_lo = 1e9
    var f_hi = -1e9
    for t in range(0, 3200, 20):
        var a = charm_angle("pennant", t, False)
        f_lo = min(f_lo, a)
        f_hi = max(f_hi, a)
    assert_true(abs(f_lo + 12.0) < 0.2 and abs(f_hi + 5.0) < 0.2, "the pennant flaps -12..-5")
    assert_equal(charm_angle("bag", 900, True), 0.0)
    assert_equal(charm_angle("hat", 900, False), 16.0)
    print("swing and flap: ok")


def main() raises:
    var sw = 1100
    var sheet = List[UInt32](length=sw * 430, fill=rgba(235, 235, 240))
    test_paths()
    test_icons(sheet, sw)
    test_charms(sheet, sw)
    test_motion()
    try:
        with open("build/g77/vector-sheet.png", "w") as f:
            f.write_bytes(Span(encode_png(sheet, sw, 430)))
    except:
        pass
    print("vector: ok")
