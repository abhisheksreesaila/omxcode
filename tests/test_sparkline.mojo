# mojoui.sparkline (goal 33 M4): the points and scaling of model-page.js's areaChart (min/max, a flat series, one
# point, none, below zero), what draw() paints (line, area, nothing above), and the benchmark's bars.
#   scripts/mxbuild.sh tests/test_sparkline.mojo -o build/test_sparkline && build/test_sparkline
from std.testing import assert_equal, assert_true, assert_false, assert_almost_equal
from mojoui.canvas import Surface, rgba
from mojoui.theme import Palette
from mojoui.view import CANVAS
from mojoui.sparkline import (spark_points, Sparkline, SparklineView, bar_fractions, bar_order, BarTrack, BarView,
                              SPARK_HEIGHT)


def near(got: List[Float64], want: List[Float64], what: String) raises:
    assert_equal(len(got), len(want), what)
    for i in range(len(want)):
        assert_almost_equal(got[i], want[i], atol=1e-9, msg=what + " [" + String(i) + "]")


def points() raises:
    # in the original's own box (600 × 84): x evenly spread; 0 sits 4 from the bottom, the highest 6 from the top
    near(spark_points([1.0, 2.0, 3.0], 600, 84), [0, 80 - 74.0 / 3, 300, 80 - 148.0 / 3, 600, 6], "1, 2, 3")
    near(spark_points([10.0, 20.0], 600, 84), [0, 80 - 37, 600, 6], "the scale starts at 0, not at the lowest")
    near(spark_points([-2.0, 2.0], 600, 84), [0, 80, 600, 6], "below 0: the lowest is the bottom")
    near(spark_points([5.0, 5.0, 5.0], 600, 84), [0, 6, 300, 6, 600, 6], "a flat series above 0 runs along the top")
    near(spark_points([0.0, 0.0, 0.0], 600, 84), [0, 80, 300, 80, 600, 80], "all zeros: along the bottom")
    near(spark_points([7.0], 600, 84), [0, 80, 600, 80], "one point: the original's [0, 0]")
    near(spark_points(List[Float64](), 600, 84), [0, 80, 600, 80], "none: the same")
    # stretched to another box (preserveAspectRatio none): x by width, y by height / 84
    near(spark_points([0.0, 4.0], 300, 76), [0, 80.0 * 76 / 84, 300, 6.0 * 76 / 84], "scaled")


def drawing() raises:
    var w = 200
    var h = 76
    var bg = rgba(255, 255, 255)
    var ink = rgba(124, 102, 255)
    var quiet = rgba(160, 160, 160)
    var buf = List[UInt32](length=w * h, fill=bg)
    var s = Surface(Int(buf.unsafe_ptr()), w, h, 1.0)
    Sparkline([2.0, 2.0], ink, quiet).draw(s)  # a flat line at y = 6 × 76 / 84 ≈ 5.43
    var y_line = Int(Float64(6) * 76.0 / 84.0)
    assert_equal(s.get(100, y_line), ink, "the line is the colour")
    assert_equal(s.get(100, 1), bg, "nothing above the line")
    var under = s.get(100, 40)
    assert_true(under != bg and under != ink, "the area is a tint")
    var r = Int(under & 0xFF)  # 12 % of (124, 102, 255) over white
    assert_true(abs(r - Int(Float64(255) * 0.88 + 124.0 * 0.12 + 0.5)) <= 1, "the area is 12 % of the colour: " + String(r))
    assert_equal(s.get(100, h - 1), under, "the area runs to the bottom, one tint")
    # the stroke is 1.8 points: twice as many pixels on a 2× screen
    var thick1 = 0
    for y in range(h):
        if s.get(50, y) == ink:
            thick1 += 1
    var buf2 = List[UInt32](length=w * h * 4, fill=bg)
    var s2 = Surface(Int(buf2.unsafe_ptr()), w * 2, h * 2, 2.0)
    Sparkline([2.0, 2.0], ink, quiet).draw(s2)
    var thick2 = 0
    for y in range(h * 2):
        if s2.get(100, y) != bg and (s2.get(100, y) & 0xFF) < 200:
            thick2 += 1
    assert_true(thick1 >= 1 and thick2 >= 3, "non-scaling stroke: " + String(thick1) + " / " + String(thick2))
    # nothing to show: a quiet flat line at the bottom, no area
    var buf3 = List[UInt32](length=w * h, fill=bg)
    var s3 = Surface(Int(buf3.unsafe_ptr()), w, h, 1.0)
    var one = Sparkline([9.0], ink, quiet)
    assert_false(one.live())
    one.draw(s3)
    assert_equal(s3.get(100, Int(Float64(80) * 76.0 / 84.0)), quiet, "the quiet line")
    assert_equal(s3.get(100, 30), bg, "no area")
    assert_equal(s3.get(100, h - 1), bg, "no area below either")
    # themed: the palette's first series colour, quiet in ink3
    var p = Palette.plain()
    var t = Sparkline.themed([1.0, 2.0], p)
    assert_equal(t.color, p.series[0])
    assert_equal(t.quiet, p.ink3)
    _ = len(buf), len(buf2), len(buf3)  # (the surfaces point into them: keep them alive to here)
    var v = SparklineView(7, 3)
    assert_equal(v.nodes[0].kind, CANVAS)
    assert_equal(v.nodes[0].style, 7)
    assert_equal(v.nodes[0].h, SPARK_HEIGHT)
    assert_equal(v.nodes[0].name, "sparkline")


def bars() raises:
    near(bar_fractions([157.9, 42.0, 0.0]), [1.0, 42.0 / 157.9, 0.0], "value / largest")
    near(bar_fractions([0.0, 0.0]), [0.0, 0.0], "nothing above 0")
    var names: List[String] = ["b", "a", "c"]
    var o = bar_order([10.0, 10.0, 30.0], names, False)
    assert_equal(o[0], 2)
    assert_equal(o[1], 1, "ties by name")
    assert_equal(o[2], 0)
    var lo = bar_order([42.0, 18.0, 30.0], names, True)
    assert_equal(lo[0], 1, "lower is better: smallest first")
    assert_equal(lo[2], 0)
    var w = 100
    var h = 12
    var bg = rgba(255, 255, 255)
    var fill = rgba(11, 11, 13)
    var track = rgba(227, 227, 232)
    var buf = List[UInt32](length=w * h, fill=bg)
    var s = Surface(Int(buf.unsafe_ptr()), w, h, 1.0)
    BarTrack(0.5, fill, track, 0).draw(s)
    assert_equal(s.get(25, 6), fill, "filled to half")
    assert_equal(s.get(75, 6), track, "the rest is the track")
    assert_equal(s.get(0, 0), bg, "rounded corners")
    var buf2 = List[UInt32](length=w * h, fill=bg)
    var s2 = Surface(Int(buf2.unsafe_ptr()), w, h, 1.0)
    var ink = rgba(11, 11, 13)
    BarTrack(0.0, rgba(255, 0, 0), track, ink).draw(s2)
    assert_equal(s2.get(50, 0), ink, "this model's ring")
    assert_equal(s2.get(50, 6), track, "inside the ring")
    _ = len(buf), len(buf2)
    assert_equal(BarTrack.themed(1.0, Palette.plain()).fill, Palette.plain().accent)
    assert_equal(BarView(3, 1).nodes[0].h, 12)


def main() raises:
    points()
    drawing()
    bars()
    print("sparkline: ok")
