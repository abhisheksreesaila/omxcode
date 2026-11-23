# mojoui.glyphwarm (D-8002): what one process drew is ready in the next before it draws. Two processes: "make" shapes and
# rasters text in several faces, sizes and scripts (fallback faces and an emoji too) and saves; "warm" reads the file in
# slices, then draws the same text: nothing is left to raster, and every image's pixels equal the first process's. The
# file holds glyph ids, sizes and fonts, never text. A missing or broken file warms nothing and says so. `glyphwarm: ok`.
#   B=build/test_glyphwarm; pixi run mojo build -I . -I vendor tests/test_glyphwarm.mojo -o $B && $B make && $B warm
from std.os import getenv
from std.sys import argv
from std.testing import assert_true, assert_equal
from mojoui.fonttext import engine, shape, TextStyle
from mojoui.glyphwarm import GlyphWarm

comptime PATH = "build/test_glyphwarm.txt"


def draw() raises -> Int:
    """The sample drawn as a renderer would ask for it; a hash of every image's pixels."""
    var texts: List[String] = ["Secret plan 42", "नमस्ते", "你好，世界", "Trip 📚 ok", "Ångström fi"]
    var styles = List[TextStyle]()
    styles.append(TextStyle("Geist", 400, False, 14))
    styles.append(TextStyle("Geist", 600, False, 13))
    styles.append(TextStyle("Source Serif 4", 400, True, 18))
    styles.append(TextStyle("Geist Mono", 400, False, 11))
    var e = engine()
    var h: UInt64 = 1469598103934665603
    for st in styles:
        for t in texts:
            var r = shape(st, t)
            for ref g in r.glyphs:
                for k in [1.0, 1.6, 2.0]:
                    var i = e[].image(g.inst, g.gid, st.size * k, 0)
                    h = (h ^ UInt64(e[].images[i].w * 31 + e[].images[i].h)) * 1099511628211
                    for b in e[].images[i].cov:
                        h = (h ^ UInt64(b)) * 1099511628211
                    for b in e[].images[i].rgba:
                        h = (h ^ UInt64(b)) * 1099511628211
    return Int(h >> 2)


def main() raises:
    var args = argv()
    if len(args) > 1 and args[1] == "make" or getenv("GW_MODE") == "make":  # (GW_MODE: a runner that passes no arguments, scripts/mac-ssh-test)
        var h = draw()
        var w = GlyphWarm(PATH)
        assert_true(w.save(), "saved")
        assert_true(not w.save(), "nothing new: not written again")
        with open(PATH + ".hash", "w") as f:
            f.write(String(h))
        with open(PATH, "r") as f:
            var t = f.read()
            assert_true(t.find("Secret") < 0 and t.find("plan") < 0 and t.find("你") < 0, "no text in the file")
        print("glyphwarm: made, " + String(len(engine()[].image_of)) + " images")
        return
    var w = GlyphWarm(PATH)
    var slices = 1
    while w.step(500):
        slices += 1
    var n = len(engine()[].image_of)
    assert_true(slices > 2, "a slice at a time")
    var h = draw()
    assert_equal(len(engine()[].image_of), n, "nothing left to raster")
    with open(PATH + ".hash", "r") as f:
        assert_equal(f.read(), String(h), "the same pixels")
    assert_true(not w.save(), "nothing new to keep")
    var none = GlyphWarm("build/no-such-file.txt")
    assert_true(not none.step(500) and none.warmed == 0, "no file")
    with open("build/test_glyphwarm_bad.txt", "w") as f:
        f.write("G\tx\ty\nS\t\nG\t1\t2\t0\t400\t16\tp:0:/no/such/font.ttf\nnonsense\n")
    var bad = GlyphWarm("build/test_glyphwarm_bad.txt")
    while bad.step(500):
        pass
    assert_equal(bad.warmed, 0, "a broken file warms nothing")
    var asc = GlyphWarm("build/no-such-file.txt")  # the first run of all: a style's printable ASCII
    asc.add_ascii(TextStyle("Figtree", 500, False, 15), 2.0)
    asc.touch()
    assert_true(asc.idle_step(500) and asc.warmed == 0, "nothing while input is fresh")
    while asc.step(500):
        pass
    var before = len(engine()[].image_of)
    var fr = shape(TextStyle("Figtree", 500, False, 15), "Quick notes (3) & more!")
    for ref g in fr.glyphs:
        if g.gid != 0:
            _ = engine()[].image(g.inst, g.gid, 30.0, 0)
    assert_true(len(engine()[].image_of) - before <= 1, "its glyphs were ready (the space is the one ASCII leaves out)")
    print("glyphwarm: ok (" + String(n) + " images in " + String(slices) + " slices, " + String(w.ms) + " ms)")
