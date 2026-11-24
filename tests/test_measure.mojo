# fonttext.measure (D-8007) asks the shaping engine once per (style, text): its answer equals the shaped run's width in
# every face, size, weight and script tried, and asking again (or after drawing the run) shapes nothing. `measure: ok`.
#   pixi run mojo run -I . -I vendor tests/test_measure.mojo
from std.testing import assert_true, assert_equal
from mojoui.fonttext import engine, measure, shape, TextStyle


def main() raises:
    var texts: List[String] = ["Projects", "12 notes", "Ångström fi", "नमस्ते दुनिया", "こんにちは世界", "Trip 📚 ok", ""]
    var styles = List[TextStyle]()
    for s in [11.0, 13.0, 14.5, 18.0]:
        styles.append(TextStyle("Geist", 400, False, s))
        styles.append(TextStyle("Geist", 600, False, s))
        styles.append(TextStyle("Source Serif 4", 400, True, s))
        styles.append(TextStyle("Geist Mono", 500, False, s))
    var e = engine()
    for st in styles:
        for t in texts:
            var want = e[].shape(st, t).width
            assert_equal(measure(st, t), want, "width of '" + t + "'")
    var n = e[].shapings
    for _ in range(3):
        for st in styles:
            for t in texts:
                _ = measure(st, t)
    assert_equal(e[].shapings, n, "asked again: nothing shaped")
    var st = TextStyle("Geist", 500, False, 17)
    _ = shape(st, "drawn first")  # (a run already drawn answers too)
    n = e[].shapings
    assert_true(measure(st, "drawn first") > 0)
    assert_equal(e[].shapings, n, "a drawn run's width is known")
    for i in range(40000):  # (bounded: a wrap's many trials don't grow it without end)
        _ = measure(st, "trial " + String(i % 33000))
    assert_true(len(e[].widths) <= 32768, "the widths are bounded")
    print("measure: ok")
