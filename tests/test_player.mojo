# mojoui.player's Player and the line chart's time cursor (goal 39 M2), on the generated drone footage and its telemetry:
#   G39_MEDIA=build/g39/media pixi run mojo run -I . tests/test_player.mojo
# Prints "player: ok" and "cursor: ok" (scripts/check.py m2 reads them). Frames are compared with VideoSource's own reads
# (itself checked against ffmpeg in test_video); the telemetry against Python's csv module, used only here.
from std.testing import assert_equal, assert_true
from std.os import getenv
from std.python import Python
from mojoui.player import Player, PlayerState, clock_text, PLAY, PAUSE, SCRUB, VIDEO, FRAME
from mojoui.app import Event
from mojoui.view import PRESS, PAN, KEY
from mojoui.video import VideoSource
from mojoui.canvas import Surface
from mojoui.charts import LineChart
from mojoui.chartview import ChartView
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.timeseries import TimeSeries


def blank(w: Int, h: Int) -> List[UInt32]:
    return List[UInt32](length=w * h, fill=0)


def near(a: Float64, b: Float64, eps: Float64 = 1e-9) raises:
    assert_true(abs(a - b) <= eps, String(a) + " is not " + String(b))


def state_tests() raises:
    # 30 fps, 29 s: one second of display frames (60 Hz) plays one second
    var s = PlayerState(30.0, 870, 29.0)
    assert_equal(s.time_text(), "0:00 / 0:29")
    s.play()
    var moved = 0
    for _ in range(60):
        if s.tick(16_667):
            moved += 1
    assert_equal(s.frame, 30)
    near(s.t(), 1.0)
    assert_equal(moved, 30)  # (a frame every second display frame)
    assert_equal(s.time_text(), "0:01 / 0:29")
    # a stall drops frames instead of falling behind
    _ = s.tick(200_000)
    assert_equal(s.frame, 36)
    # a very long stall catches up by at most a quarter of a second
    _ = s.tick(5_000_000)
    assert_equal(s.frame, 43)
    # pause stops the clock
    s.pause()
    assert_equal(s.tick(1_000_000), False)
    assert_equal(s.frame, 43)
    # seek is frame-accurate, and clamps
    s.seek(12.5)
    assert_equal(s.frame, 375)
    near(s.t(), 12.5)
    s.seek(12.51)
    assert_equal(s.frame, 375)
    s.seek(12.534)
    assert_equal(s.frame, 376)
    s.seek(-3.0)
    assert_equal(s.frame, 0)
    s.seek(500.0)
    assert_equal(s.frame, 869)
    # step ±1 pauses and moves one frame
    s.seek(12.5)
    s.play()
    s.step(1)
    assert_equal(s.frame, 376)
    assert_equal(s.playing, False)
    s.step(-1)
    s.step(-1)
    assert_equal(s.frame, 374)
    s.step(-100000)
    assert_equal(s.frame, 0)
    s.step(100000)
    assert_equal(s.frame, 869)
    # the end stops cleanly on the last frame; play from there starts again
    s.seek(28.9)
    s.play()
    assert_equal(s.tick(200_000), True)
    assert_equal(s.playing, False)
    assert_equal(s.frame, 869)
    near(s.clock, 29.0)
    assert_equal(s.time_text(), "0:28 / 0:29")
    s.play()
    assert_equal(s.playing, True)
    assert_equal(s.frame, 0)
    assert_equal(clock_text(3723.0), "1:02:03")
    assert_equal(clock_text(59.9), "0:59")


def pixel_of(frame: List[UInt32], w: Int, x: Int, y: Int) -> UInt32:
    return frame[y * w + x]


def player_tests(media: String) raises:
    var player = Player(media + "/drone_a.mp4", msg_base=100, canvas_base=100)
    assert_equal(player.state.frames, 870)
    assert_equal(player.state.fps, 30.0)
    near(player.state.duration, 29.0, 1e-6)
    assert_equal(player.owns(104), True)
    assert_equal(player.owns(105), False)
    var oracle = VideoSource(media + "/drone_a.mp4")
    var w = 1280
    var h = 720
    var backdrop = UInt32(0xFFE9EEF4)
    var pal = Palette.plain()

    # messages: play, frames from the display, pause
    assert_equal(player.update(Event(100 + PLAY, "", 0)), True)
    assert_equal(player.state.playing, True)
    for _ in range(30):
        _ = player.update(Event(100 + FRAME, "", 33_334))  # 30 display frames of 1/30 s: one second
    assert_equal(player.state.frame, 30)
    _ = player.update(Event(100 + PAUSE, "", 0))
    assert_equal(player.state.playing, False)
    _ = player.update(Event(100 + FRAME, "", 33_333))
    assert_equal(player.state.frame, 30)
    assert_equal(player.update(Event(7, "", 0)), False)

    # the scrubber: a touch at the middle of a 500-point track seeks to the middle of the video
    var scrub = blank(520, 28)
    var ss = Surface(Int(scrub.unsafe_ptr()), 520, 28, 1.0)
    player.draw(101, ss, backdrop, pal)
    near(player.scrub_w, 520.0)
    _ = player.update(Event(100 + SCRUB, "", PRESS, x=10.0 + 250.0))
    assert_equal(player.state.frame, 435)
    _ = player.update(Event(100 + SCRUB, "", PAN, x=10.0, dx=-3.0))
    assert_equal(player.state.frame, 0)
    _ = player.update(Event(100 + SCRUB, "", PAN, x=900.0))
    assert_equal(player.state.frame, 869)
    # keys: Space plays, the arrows step
    player.state.seek(10.0)
    _ = player.update(Event(100 + VIDEO, " ", KEY))
    assert_equal(player.state.playing, True)
    _ = player.update(Event(100 + VIDEO, "ArrowLeft", KEY))
    assert_equal(player.state.playing, False)
    assert_equal(player.state.frame, 299)

    # the picture is the frame, exactly (1:1 on a 1280x720 surface): a seek lands on the frame ffmpeg shows at that time
    var px = blank(w, h)
    var surface = Surface(Int(px.unsafe_ptr()), w, h, 1.0)
    player.state.seek(7.0)
    player.draw(100, surface, backdrop, pal)
    var want = oracle.read(210)
    assert_equal(pixel_of(px, w, 640, 360), pixel_of(want, w, 640, 360))
    assert_equal(pixel_of(px, w, 100, 500), pixel_of(want, w, 100, 500))
    assert_equal(pixel_of(px, w, 1000, 200), pixel_of(want, w, 1000, 200))
    # one frame back, one frame on
    player.state.step(-1)
    player.draw(100, surface, backdrop, pal)
    want = oracle.read(209)
    assert_equal(pixel_of(px, w, 640, 360), pixel_of(want, w, 640, 360))
    assert_equal(pixel_of(px, w, 300, 100), pixel_of(want, w, 300, 100))
    player.state.step(2)
    player.draw(100, surface, backdrop, pal)
    want = oracle.read(211)
    assert_equal(pixel_of(px, w, 640, 360), pixel_of(want, w, 640, 360))
    assert_equal(pixel_of(px, w, 300, 100), pixel_of(want, w, 300, 100))
    # frames read on in order while playing, and a jump ahead of a few frames lands right too
    player.state.seek(7.5)
    player.state.play()
    for _ in range(3):
        _ = player.state.tick(33_334)
        player.draw(100, surface, backdrop, pal)
    want = oracle.read(228)
    assert_equal(player.state.frame, 228)
    assert_equal(pixel_of(px, w, 640, 360), pixel_of(want, w, 640, 360))
    # the corners are rounded (the backdrop shows), and the picture is centred and fitted in a wide, short surface
    assert_equal(pixel_of(px, w, 0, 0), backdrop)
    assert_equal(pixel_of(px, w, w - 1, h - 1), backdrop)
    var wide = blank(1000, 300)
    var ws = Surface(Int(wide.unsafe_ptr()), 1000, 300, 1.0)
    player.draw(100, ws, backdrop, pal)
    assert_equal(wide[150 * 1000 + 10], backdrop)  # (left of the 533-wide picture)
    assert_equal(wide[150 * 1000 + 990], backdrop)
    assert_true(wide[150 * 1000 + 500] != backdrop)
    assert_equal(wide[0], backdrop)
    # the scrubber shows how far in: accent to the left of the handle, a grey track to the right
    player.state.pause()
    player.state.seek(14.5)
    player.draw(101, ss, backdrop, pal)
    assert_equal(ss.get(120, 14), pal.accent)
    assert_equal(ss.get(400, 14), pal.line_strong)
    assert_true("t=14.500 s of 29.000 s, frame 435 of 870, paused" in player.describe())
    _ = scrub[0]  # (the surfaces borrow these pixels: they must outlive the drawing)
    _ = px[0]
    _ = wide[0]
    print("player: ok")


def telemetry(media: String) raises -> List[List[Float64]]:
    """The CSV's columns (t, lat, lon, alt_m, heading_deg, speed_ms, battery_pct) read with Python's csv module."""
    var csv = Python.import_module("csv")
    var builtins = Python.import_module("builtins")
    var f = builtins.open(media + "/telemetry_a.csv", newline="")
    var cols = List[List[Float64]]()
    for _ in range(7):
        cols.append(List[Float64]())
    for row in csv.reader(f):
        if String(row[0]) == "t":
            continue
        for i in range(7):
            cols[i].append(Float64(py=builtins.float(row[i])))
    f.close()
    return cols^


def cursor_x_of(a: List[UInt32], b: List[UInt32], w: Int, h: Int) raises -> Float64:
    """The mean column of the pixels that differ between two pictures (the cursor's line and dot are symmetric about it)."""
    var sum = 0.0
    var n = 0
    for y in range(h):
        for x in range(w):
            if a[y * w + x] != b[y * w + x]:
                sum += Float64(x) + 0.5
                n += 1
    assert_true(n > 0, "the cursor drew nothing")
    return sum / Float64(n)


def cursor_tests(media: String) raises:
    var cols = telemetry(media)
    var times = cols[0].copy()
    assert_equal(len(times), 291)
    var ts = TimeSeries(times.copy())
    ts.add("alt_m", cols[3].copy())
    ts.add("speed_ms", cols[5].copy())
    ts.add("battery_pct", cols[6].copy())
    # the row for a time is the nearest 10 Hz sample, clamped at both ends
    assert_equal(ts.row_at(12.46), 125)
    assert_equal(ts.row_at(12.44), 124)
    assert_equal(ts.row_at(12.5), 125)
    assert_equal(ts.row_at(-4.0), 0)
    assert_equal(ts.row_at(99.0), 290)
    assert_equal(ts.row_at(29.0), 290)
    assert_equal(ts.row_at(0.049), 0)
    assert_equal(ts.value("alt_m", ts.row_at(12.46)), cols[3][125])
    assert_equal(ts.value("speed_ms", ts.row_at(7.0)), cols[5][70])
    assert_equal(ts.value("battery_pct", ts.row_at(29.0)), cols[6][290])
    assert_equal(ts.value("nothing", 3), 0.0)
    assert_equal(len(ts.column("alt_m")), 291)

    # the chart: a cursor at t draws at the pixel column t maps to, and moves with t
    var w = 800
    var h = 300
    var font = Font()
    var pal = Palette.plain()
    var labels = List[String]()
    for _ in range(len(times)):
        labels.append("")
    var plain = blank(w, h)
    var marked = blank(w, h)
    var ps = Surface(Int(plain.unsafe_ptr()), w, h, 1.0)
    var cs = Surface(Int(marked.unsafe_ptr()), w, h, 1.0)
    LineChart(labels.copy(), cols[3].copy()).numbers(False).fitted().with_x(times.copy()).themed(pal).draw(ps, font)
    var chart = LineChart(labels.copy(), cols[3].copy()).numbers(False).fitted().with_x(times.copy()).themed(pal)
    var box = chart.plot_box(Float64(w), Float64(h), 1.0, font)
    for t in [3.0, 12.5, 25.0]:
        LineChart(labels.copy(), cols[3].copy()).numbers(False).fitted().with_x(times.copy()).themed(pal).with_cursor(t).draw(cs, font)
        var want_x = box[0] + (box[2] - box[0]) * t / 29.0
        near(chart.x_pixel(t, box[0], box[2]), want_x, 1e-9)
        var got = cursor_x_of(plain, marked, w, h)
        assert_true(abs(got - want_x) < 1.0, "cursor at " + String(got) + ", wanted " + String(want_x))
    # a tap on the chart seeks to the time under it (the inverse mapping)
    near(chart.x_value(box[0] + (box[2] - box[0]) * 0.25, box[0], box[2]), 7.25, 1e-9)
    near(chart.x_value(-50.0, box[0], box[2]), 0.0, 1e-9)
    near(chart.x_value(5000.0, box[0], box[2]), 29.0, 1e-9)
    var view = ChartView.line("Altitude", labels.copy(), cols[3].copy())
    view.xs = times.copy()
    view.money = False
    view.floor = chart.floor
    view.size = (Float64(w), Float64(h))
    var box2 = chart.plot_box(Float64(w) * 2, Float64(h) * 2, 2.0, font)  # (the view measures in 2x pixels)
    near(view.seek_at((box2[0] + (box2[2] - box2[0]) * 0.25) / 2, font, pal), 7.25, 1e-9)
    print("cursor: ok")


def main() raises:
    var media = getenv("G39_MEDIA", "build/g39/media")
    state_tests()
    player_tests(media)
    cursor_tests(media)
