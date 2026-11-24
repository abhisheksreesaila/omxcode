# mojoui.mapmarks against Personal Note's own code (geometry.js, pencil.js, due.js run by node on these inputs, 2026-11-24).
#   pixi run mojo run -I . tests/test_mapmarks.mojo
from std.testing import assert_equal, assert_true
from mojoui.mapmarks import Frame, Curve, branch_between, pencil_outline, seed_of, due_chip, DayTime, look_of, icon_path, DUE_LATER, DUE_TODAY, DUE_OVER
from mojoui.strokeicon import icon_segments


def near(g: Curve, w: List[Float64]) raises:
    var v: List[Float64] = [g.sx, g.sy, g.ex, g.ey, g.ax, g.ay, g.bx, g.by]
    for i in range(8):
        assert_true(abs(v[i] - w[i]) < 1e-5, "branch " + String(i) + ": " + String(v[i]) + " not " + String(w[i]))


def main() raises:
    var p = Frame(0, 0, 90, 38)
    var c = Frame(280, -130, 60, 21)
    near(branch_between(p, c), [54.635885, -25.366661, 236.583249, -109.842223, 128.986275, -8.136015, 201.765221, -41.92624])
    near(branch_between(p, c, 20, List[Float64](), "top", "left"), [48.647665, -25.436076, 221, -130, 109.536246, -41.669144, 178.47718, -83.494714])
    near(branch_between(p, c, 78, List[Float64](), "right", "bottom"), [78, 0, 241.632325, -109.860571, 152.416391, 4.764787, 217.869321, -39.179441])
    near(branch_between(p, Frame(-260, 40, 50, 20, True), 78, [0.2, 0.4, 0.8, -0.1]), [-60.348849, 9.284438, -260, 45, -114.565304, -63.43291, -216.498214, 57.822003])
    near(branch_between(p, Frame(30, 200, 60, 20), 78, List[Float64](), "bottom", "top"), [0, 26, 30, 181, -5.876151, 75.379255, 6.123849, 137.379255])
    assert_equal(seed_of("n10"), 814)
    assert_equal(seed_of("node-é1"), 956)
    var o = pencil_outline(-40, 35, 3, 814)
    assert_equal(len(o), 56)
    var want: List[Float64] = [-40.005284, 3.793519, -34.279948, 4.085576, -28.463746, 4.985029]
    for i in range(6):
        assert_true(abs(o[i] - want[i]) < 1e-5, "pencil")
    assert_true(abs(o[54] + 39.994716) < 1e-5 and abs(o[55] - 2.949128) < 1e-5, "its end")
    var now = DayTime(2026, 11, 24, 9, 30)
    var cases: List[String] = ["2026-11-24", "2026-11-24T09:00", "2026-11-24T15:05", "2026-11-26", "2026-11-20", "2026-12-25T00:10", "2026-11-23T23:00"]
    var words: List[String] = ["Today", "9:00 AM", "3:05 PM", "Thu", "Nov 20", "Dec 25 12:10 AM", "Nov 23 11:00 PM"]
    var states: List[Int] = [DUE_TODAY, DUE_OVER, DUE_TODAY, DUE_LATER, DUE_OVER, DUE_LATER, DUE_OVER]
    for i in range(7):
        var r = due_chip(cases[i], now)
        assert_equal(r[0], words[i])
        assert_equal(r[1], states[i])
    assert_equal(due_chip("2026-02-30", now)[0], "")
    assert_equal(due_chip("bad", now)[0], "")
    var l = look_of('"icons":["todo","star","nope","flag","x"],"done":true,"collapsed":true,"presentation":"branch","branchPorts":{"source":"top","target":null},"curve":20')
    assert_true(l.done and l.collapsed and l.branch and l.source == "top" and l.target == "" and l.curve == 20, "read")
    assert_equal(String(" ".join(l.shown_icons())), "done star")
    assert_equal(look_of('"curve":"odd","branchAnchors":[1]').curve, 78)
    for n in ["todo", "done", "flag", "star", "alert", "question", "clock", "idea", "heart", "pin", "fire", "x"]:
        assert_true(len(icon_segments(icon_path(String(n)))) >= 8, String(n))
    print("mapmarks: ok")
