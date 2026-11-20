# mojoui.fonttext_check (goal 79 M1): the checks behind tests/test_fonttext.mojo, kept in the framework so an app can
# print the same lines on a machine where the test can't run (the Mac: pnote with PNOTE_FONTCHECK=1).
#
# Prints, for every line of the fixture (docs/goals/79/fixture.json's textlines):
#   WIDTH <id> <device px>     the run's advance width at the device scale (the checker compares it with Chromium's)
#   NOTDEF <id> <n>            glyphs that came out as .notdef
#   CRISP <ratio>              a word drawn through a 4× zoomed layer vs the same word rasterized directly at 4×:
#                              mean edge strength (gradient magnitude), zoomed / direct
# and `fonttext: ok` when nothing is missing (the widths are the checker's to judge).

from mojoui.fonttext import TextStyle, engine, shape, draw_run, Clip
from mojoui.json import Json
from mojoui.canvas import Surface, rgba
from mojoui.scene import SurfacePainter


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def edge_strength(px: List[UInt32], w: Int, h: Int) -> Float64:
    """Mean gradient magnitude of the grey picture over pixels that have any (a blurred word scores lower)."""
    var total = 0.0
    var n = 0
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            var c = Float64(Int(px[y * w + x] & 0xFF))
            var gx = Float64(Int(px[y * w + x + 1] & 0xFF)) - Float64(Int(px[y * w + x - 1] & 0xFF))
            var gy = Float64(Int(px[(y + 1) * w + x] & 0xFF)) - Float64(Int(px[(y - 1) * w + x] & 0xFF))
            var g = (gx * gx + gy * gy) ** 0.5
            if g > 8:
                total += g
                n += 1
            _ = c
    return total / Float64(n) if n > 0 else 0.0


def crispness(dpr: Float64) -> Float64:
    """A word at 4× zoom through a SurfacePainter layer (the way a zoomed canvas draws its text) vs the same word
    rasterized directly at 4×: if the zoomed path scaled a 1× bitmap, its edges would be ~4× softer."""
    var st = TextStyle("Source Serif 4", 400, False, 15)
    var run = shape(st, "Harbour")
    var k = dpr * 4
    var w = Int(run.width * k) + 40
    var h = Int(st.size * k * 1.6) + 20
    var a = List[UInt32](length=w * h, fill=0xFFFFFFFF)
    var b = List[UInt32](length=w * h, fill=0xFFFFFFFF)
    var sp = SurfacePainter(Surface(Int(a.unsafe_ptr()), w, h, dpr))
    sp.begin_layer("zoomed")
    sp.layer_transform(10, 0, k)
    sp.run(st, "Harbour", 0, st.size * 1.2, rgba(20, 20, 20), 0)
    var sb = Surface(Int(b.unsafe_ptr()), w, h, dpr)
    draw_run(sb, run, 10, st.size * 1.2 * k, k, rgba(20, 20, 20), Clip(0, 0, w, h))
    var ea = edge_strength(a, w, h)
    var eb = edge_strength(b, w, h)
    return ea / eb if eb > 0 else 0.0


def fontcheck(ref_path: String, fixture_path: String, dpr: Float64) raises -> Bool:
    var fx = Json.parse(_read(fixture_path))
    var lines = fx.get(0, "textlines")
    var ok = True
    var e = engine()
    if e[].error != "":
        print("fonttext: FAIL " + e[].error)
        return False
    for i in range(fx.size(lines)):
        var l = fx.at(lines, i)
        var id = fx.text(fx.get(l, "id"))
        var st = TextStyle(fx.text(fx.get(l, "family")), fx.number(fx.get(l, "weight")), fx.text(fx.get(l, "style")) == "italic",
                           fx.real(fx.get(l, "size")))
        var text = fx.text(fx.get(l, "text"))
        var run = shape(st, text)
        print("WIDTH " + id + " " + String(run.width * dpr))
        print("NOTDEF " + id + " " + String(run.missing))
        if run.missing != 0 or len(run.glyphs) == 0:
            ok = False
        # it draws (every glyph rasterizes) at the device scale
        var w = Int(run.width * dpr) + 20
        var h = Int(st.size * dpr * 2) + 10
        var px = List[UInt32](length=w * h, fill=0xFFFFFFFF)
        var s = Surface(Int(px.unsafe_ptr()), w, h, dpr)
        draw_run(s, run, 10, st.size * dpr * 1.3, dpr, rgba(17, 17, 20), Clip(0, 0, w, h))
        var inked = 0
        for p in px:
            if p != 0xFFFFFFFF:
                inked += 1
        if inked == 0:
            print("fonttext: " + id + " drew nothing")
            ok = False
    var c = crispness(dpr)
    print("CRISP " + String(c))
    if ok:
        print("fonttext: ok")
    _ = ref_path
    return ok
