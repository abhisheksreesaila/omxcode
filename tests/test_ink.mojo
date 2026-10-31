# Pressure ink (goal 40 M0): a stroke's points and pressures become one closed outline whose width follows the
# pressure; with no device pressure the width comes from speed; the smoothed outline stays centred on every point;
# a point on the ink hits the stroke, one 2 px outside doesn't (the eraser's test).
#   pixi run mojo run -I . tests/test_ink.mojo
from std.math import sqrt, isnan
from std.testing import assert_true, assert_false

from mojoui.ink import Stroke, ink_width


def extent_at(pts: List[Float64], x: Float64) -> Tuple[Float64, Float64]:
    """The outline's lowest and highest y where the vertical line at x crosses it."""
    var lo = 1e30
    var hi = -1e30
    var n = len(pts) // 2
    for i in range(n):
        var j = (i + 1) % n
        var xa = pts[2 * i]
        var xb = pts[2 * j]
        if (xa <= x and x < xb) or (xb <= x and x < xa):
            var y = pts[2 * i + 1] + (x - xa) * (pts[2 * j + 1] - pts[2 * i + 1]) / (xb - xa)
            lo = min(lo, y)
            hi = max(hi, y)
    return (lo, hi)


def inside(pts: List[Float64], x: Float64, y: Float64) -> Bool:
    """Non-zero winding."""
    var w = 0
    var n = len(pts) // 2
    for i in range(n):
        var j = (i + 1) % n
        var ya = pts[2 * i + 1]
        var yb = pts[2 * j + 1]
        if (ya <= y and y < yb) or (yb <= y and y < ya):
            var cx = pts[2 * i] + (y - ya) * (pts[2 * j] - pts[2 * i]) / (yb - ya)
            if cx > x:
                w += 1 if yb > ya else -1
    return w != 0


def edge_distance(pts: List[Float64], x: Float64, y: Float64) -> Float64:
    var best = 1e30
    var n = len(pts) // 2
    for i in range(n):
        var j = (i + 1) % n
        var ax = pts[2 * i]
        var ay = pts[2 * i + 1]
        var dx = pts[2 * j] - ax
        var dy = pts[2 * j + 1] - ay
        var l2 = dx * dx + dy * dy
        var t = 0.0 if l2 == 0 else min(max(((x - ax) * dx + (y - ay) * dy) / l2, 0.0), 1.0)
        var ex = x - (ax + t * dx)
        var ey = y - (ay + t * dy)
        best = min(best, sqrt(ex * ex + ey * ey))
    return best


def test_outline() raises:
    var s = Stroke(12.0, 0xFF000000)
    var ps: List[Float64] = [0.1, 0.3, 0.5, 0.7, 0.9, 1.0, 0.6, 0.2]
    for i in range(len(ps)):
        s.add(40.0 + 30.0 * Float64(i), 100.0, ps[i])
    var o = s.outline()
    assert_true(len(o) >= 2 * 3 and len(o) % 2 == 0, "a polygon")
    for v in o:
        assert_false(isnan(v), "no NaN in the outline")
    for i in range(len(ps)):
        var e = extent_at(o, 40.0 + 30.0 * Float64(i) + 0.01)
        var got = e[1] - e[0]
        var want = ink_width(12.0, ps[i])
        assert_true(abs(got - want) <= 0.05 * want, "width at point " + String(i) + ": " + String(got) + " want " + String(want))
    var one = Stroke(8.0, 0)
    one.add(10, 10, 1.0)
    var d = one.outline()
    assert_true(len(d) >= 16 and inside(d, 10, 10) and not inside(d, 15, 10), "a single point is a disc")
    print("ink outline: ok")


def test_pressure_from_speed() raises:
    var slow = Stroke(10.0, 0)
    var fast = Stroke(10.0, 0)
    for i in range(30):
        slow.add(Float64(i) * 2.0, 0, 0)  # (2 px a step: slow)
        fast.add(Float64(i) * 40.0, 0, 0)  # (40 px a step: fast)
    var last_slow = slow.ps[len(slow.ps) - 1]
    var last_fast = fast.ps[len(fast.ps) - 1]
    assert_true(last_slow > 0.95, "slow is full width: " + String(last_slow))
    assert_true(last_fast < 0.45, "fast is thin: " + String(last_fast))
    var dev = Stroke(10.0, 0)
    dev.add(0, 0, 0.42)
    dev.add(50, 0, 0.42)
    assert_true(dev.ps[1] == 0.42, "a device's pressure wins over speed")
    print("ink pressure: ok")


def test_smooth() raises:
    var s = Stroke(10.0, 0)
    for i in range(24):
        var x = 20.0 + 12.0 * Float64(i)
        var y = 100.0 + 30.0 * (1.0 if (i // 4) % 2 == 0 else -1.0) * Float64(i % 4) / 4.0  # (a wave, gentle turns)
        s.add(x, y, 0.5 + 0.02 * Float64(i))
    var o = s.outline()
    for i in range(s.points()):
        var r = ink_width(10.0, s.ps[i]) / 2
        assert_true(inside(o, s.xs[i], s.ys[i]), "point " + String(i) + " is inside the ink")
        var d = edge_distance(o, s.xs[i], s.ys[i])
        assert_true(abs(d - r) <= 0.5, "point " + String(i) + " is centred: edge at " + String(d) + ", half-width " + String(r))
    print("ink smooth: ok")


def test_hit() raises:
    var s = Stroke(10.0, 0)
    s.add(0, 0, 1.0)
    s.add(50, 0, 1.0)
    s.add(100, 0, 1.0)
    s.add(100, 60, 1.0)  # (a corner: the line from (50, 0) to (100, 0) stays straight, the curve turns after it)
    assert_true(s.hits(25, 4.5, 0), "within the width")
    assert_true(s.hits(105.5 - 1.0, 30, 0) and not s.hits(107.0, 30, 0), "along the second leg")
    assert_true(s.hits(0, -4.5, 0), "at the start")
    assert_false(s.hits(25, 7.0, 0), "2 px outside")
    assert_false(s.hits(-7.0, 0, 0), "2 px past the round start")
    assert_true(s.hits(25, 7.0, 3.0), "with slop")
    var d = Stroke(10.0, 0)
    d.add(5, 5, 1.0)
    assert_true(d.hits(9, 5, 0) and not d.hits(12, 5, 0), "a dot")
    print("ink hit: ok")


def main() raises:
    test_outline()
    test_pressure_from_speed()
    test_smooth()
    test_hit()
