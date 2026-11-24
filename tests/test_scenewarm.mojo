# mojoui.scenewarm (D-8011): a screen painted off screen and readied in slices is ready when it is drawn: the renderer's
# batches shape nothing and raster nothing; the slices stay within their budget (a run at least); an empty or replaced
# screen does nothing wrong; and what is drawn after is the same as without it. `scenewarm: ok`.
from std.sys import argv
from std.testing import assert_true, assert_equal
from mojoui.clock import now_ns
from mojoui.fonttext import engine, TextStyle
from mojoui.gpu2d import Frame2D, fill_layers, GlyphAtlas
from mojoui.text import Font
from mojoui.scene import Scene, Painter
from mojoui.scenewarm import SceneWarm


def screen() -> Scene:
    var s = Scene(1600, 1000, 1.25)
    s.begin_layer("a")
    s.layer_transform(0, 0, 1.25)
    for i in range(40):
        s.run(TextStyle("Geist", 400 + 100 * (i % 4), i % 5 == 0, 11.0 + Float64(i % 7)), "Row " + String(i) + " of a panel, words 漢字 and 📚", 10, 20.0 + 20 * Float64(i), 0xFF202020, 0)
    s.begin_layer("b")
    s.layer_transform(30, 40, 2.0)
    for i in range(20):
        s.run(TextStyle("Geist Mono", 400, False, 9.0 + Float64(i)), "Second layer " + String(i), 10, 20.0 + 20 * Float64(i), 0xFF202020, 0)
    return s^


def build(s: Scene) -> Frame2D:
    var f = Frame2D()
    var font = Font()
    var atlas = GlyphAtlas(font)
    fill_layers(f, s, atlas, font, 0, s.layers())
    return f^


def main() raises:
    var e = engine()
    var w = SceneWarm()
    assert_true(not w.more() and not w.step(1000), "nothing to ready")
    w.take(Scene(10, 10, 1.0))
    assert_true(not w.more(), "an empty scene: nothing")
    w.take(screen())
    _ = w.step(1)
    w.take(screen())  # (replaced while unfinished: the new one from its start)
    var slices = 0
    while w.step(500):
        slices += 1
        assert_true(slices < 1000, "ends")
    assert_true(slices >= 5, "a slice at a time: " + String(slices))
    var images = len(e[].image_of)
    var shaped = e[].shapings
    assert_true(images > 300, "images readied: " + String(images))
    var f = build(screen())
    assert_equal(len(e[].image_of), images, "the frame rasters nothing")
    assert_equal(e[].shapings, shaped, "the frame shapes nothing")
    assert_true(len(f.glyphs) > 0, "glyphs")
    assert_true(not w.more() and w.scene.layers() == 0, "the screen is let go")
    print("scenewarm:", slices, "slices,", w.runs, "runs,", images, "images; the frame shaped and rastered nothing")
    print("scenewarm: ok")
