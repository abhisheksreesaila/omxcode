# Goal 47: mojoui.signal (unwrap, smooth, steps, peaks) and mojoui.telemetrychart (lanes from column families, a shared
# cursor, marks, spec lines), drawn on the Liquid dark palette. No files, no engine.
#   pixi run mojo run -I . tests/test_telemetry.mojo
# Prints "signal: ok", "lanes: ok", "draw: ok", "seek: ok".
from std.testing import assert_equal, assert_true
from std.math import pi, sin
from mojoui.canvas import Surface
from mojoui.text import Font
from mojoui.png import encode_png
from mojoui.timeseries import TimeSeries
from mojoui.signal import unwrap, smooth, steps, peaks, span_of
from mojoui.telemetrychart import TelemetryChart, lanes_of, family_of, member_of, family_title
from themes.liquid import liquid_dark_palette


def near(a: Float64, b: Float64, eps: Float64 = 1e-9) -> Bool:
    return abs(a - b) <= eps


def count_near(px: List[UInt32], c: UInt32, tol: Int = 10) -> Int:
    var n = 0
    for p in px:
        var close = True
        for sh in range(0, 24, 8):
            var d = Int((p >> UInt32(sh)) & 255) - Int((c >> UInt32(sh)) & 255)
            if d > tol or d < -tol:
                close = False
        if close:
            n += 1
    return n


def main() raises:
    # unwrap: a yaw that crosses ±π reads as one smooth turn
    var yaw: List[Float64] = [3.0, 3.1, -3.1, -3.0, -2.9]
    var u = unwrap(yaw)
    assert_true(near(u[2], -3.1 + 2 * pi) and near(u[4], -2.9 + 2 * pi), "unwrapped across +π")
    var down: List[Float64] = [-3.0, -3.1, 3.1, 3.0]
    var u2 = unwrap(down)
    assert_true(near(u2[2], 3.1 - 2 * pi), "unwrapped across -π")
    # smooth: a centred mean, ends shrink, window 1 is a copy
    var v: List[Float64] = [0.0, 0.0, 9.0, 0.0, 0.0]
    var s = smooth(v, 3)
    assert_true(near(s[1], 3.0) and near(s[2], 3.0) and near(s[0], 0.0) and near(s[4], 0.0), "moving average")
    assert_equal(len(smooth(v, 1)), 5)
    # steps with hysteresis: the dip to 0.2 (between the thresholds) is not an "off"
    var g: List[Float64] = [0.0, 0.1, 0.6, 0.2, 0.6, 0.05, 0.0, 0.9]
    var st = steps(g, 0.25, 0.12)
    assert_equal(len(st), 3)
    assert_true(st[0].at == 2 and st[0].on and st[1].at == 5 and not st[1].on and st[2].at == 7 and st[2].on, "steps")
    var pk = peaks([0.0, 2.0, 3.0, 1.0, 0.0, 2.5, 0.0], 1.5)
    assert_true(len(pk) == 2 and pk[0] == 2 and pk[1] == 5, "peaks")
    var flat = span_of([2.0, 2.0])
    assert_true(flat[1] - flat[0] == 1.0, "a flat channel gets a span")
    print("signal: ok")

    # families → lanes
    assert_equal(family_of("joint_vel_3"), "joint_vel")
    assert_equal(family_of("pos_x"), "pos")
    assert_equal(family_of("rot_yaw"), "rot")
    assert_equal(family_of("gripper"), "gripper")
    assert_equal(family_of("track_err"), "track_err")
    assert_equal(member_of("joint_vel_3"), "3")
    assert_equal(family_title("joint_vel"), "Joint velocity")
    var times = List[Float64]()
    for i in range(150):
        times.append(Float64(i) / 15.0)
    var ts = TimeSeries(times^)
    for j in range(7):
        var col = List[Float64]()
        for i in range(150):
            col.append(0.8 * sin(Float64(i) / 10.0 + Float64(j)))
        ts.add("joint_vel_" + String(j + 1), col^)
    var grip = List[Float64]()
    for i in range(150):
        grip.append(0.6 if 40 <= i < 100 else 0.0)
    ts.add("gripper", grip^)
    for a in ["x", "y", "z"]:
        var col = List[Float64]()
        for i in range(150):
            col.append(0.3 + 0.001 * Float64(i))
        ts.add("pos_" + a, col^)
    for a in ["roll", "pitch", "yaw"]:
        var col = List[Float64]()
        for i in range(150):
            col.append(Float64(i) * 0.01)
        ts.add("rot_" + a, col^)
    ts.add("speed", List[Float64](length=150, fill=0.5))
    var lanes = lanes_of(ts, 4)
    assert_equal(len(lanes), 4)
    assert_equal(len(lanes[0].columns), 7)
    assert_equal(lanes[1].title, "Gripper")
    assert_equal(lanes[2].title, "Position")
    assert_equal(lanes[3].title, "Rotation")
    print("lanes: ok")

    # draw: 1000 × 420 px on Liquid dark: every lane's colour shows; the cursor (ink) draws; marks at the gripper's steps
    var pal = liquid_dark_palette()
    var font = Font()
    var tc = TelemetryChart(ts.copy())
    tc.limit("joint_vel", 2.175)
    assert_true(tc.lanes[0].hi >= 2.175 and tc.lanes[0].lo <= -2.175, "the limit widens its lane")
    assert_equal(tc.mark_steps("gripper", 0.25, 0.12, "closed", "opened"), 2)
    var w = 1000
    var h = 420
    var px = List[UInt32](length=w * h, fill=0)
    var surf = Surface(Int(px.unsafe_ptr()), w, h, 1.0)
    tc.draw(surf, font, pal, 5.0)
    assert_true(count_near(px, pal.card, 2) > w * h // 10, "card background")
    for i in range(4):
        assert_true(count_near(px, pal.series[i], 14) > 40, "series colour " + String(i) + " drawn")
    assert_true(count_near(px, pal.warn, 30) > 50, "the limit line")
    var said = tc.describe(5.0)
    assert_true(said.find("Joint velocity") >= 0 and said.find("Gripper 0.6") >= 0 and said.find("closed at 2.67 s") >= 0, said)
    var png = encode_png(px, w, h)
    with open("build/telemetry-chart.png", "w") as f:  # (to look at)
        f.write_bytes(Span(png))
    _ = len(px)
    print("draw: ok")

    # seek: the gutter maps to the start, the right edge to the end
    var t_mid = tc.seek_at(132.0 + (1000.0 - 132.0 - 8.0) / 2.0, 1000.0)
    assert_true(near(t_mid, 149.0 / 15.0 / 2.0, 1e-6), "the middle of the plot is the middle of the recording")
    assert_true(near(tc.seek_at(0.0, 1000.0), 0.0), "left of the plot: the start")
    print("seek: ok")
