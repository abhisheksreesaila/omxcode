# mojoui.telemetrychart: many channels of a recording drawn as stacked lanes on one clock, with one shared cursor (goal 47).
# A generic component: a robot's joints, gripper and pose; a drone's attitude and motors; any log whose columns come in
# families. A track card (mojoui.trackcard) shows one when its log has more channels than a single chart reads well.
#
#   var tc = TelemetryChart(series)                   # lanes from the column names: joint_vel_1…7 → one lane, gripper → one,
#                                                     #   pos_x/y/z → one, rot_roll/pitch/yaw → one (the first `most` families)
#   tc.smoothing = 3                                  # a centred moving average for display (mojoui.signal.smooth); 1 = raw
#   tc.limit("joint_vel", 2.175)                      # a spec line drawn at ±value in that lane (a datasheet's limit)
#   tc.mark_steps("gripper", 0.25, 0.12, "closed", "opened")   # the moments a channel turns on and off, marked on every lane
#   draw(): tc.draw(surface, font, pal, t)            # t: the cursor (the bound video's time); prints CURSOR: t=… when tracing
#   tc.seek_at(x_points, width_points)                # a tap or drag → the time under it
#   tc.describe(t)                                    # every lane's values at t, in words, for an agent
#
# A lane's family is its column name without a trailing "_<number>" or "_<axis>" (x, y, z, roll, pitch, yaw, w). Its title
# is the family in words ("joint_vel" → "Joint velocity"). Colours are the palette's series, in order; nothing else.

from mojoui.canvas import Surface
from mojoui.charts import fixed
from mojoui.clock import trace_on
from mojoui.draw import rect, line, circle, with_alpha
from mojoui.player import clock_text
from mojoui.signal import smooth, steps, span_of
from mojoui.text import Font, MEDIUM, REGULAR, MONO, RIGHT
from mojoui.theme import Palette, mix
from mojoui.timeseries import TimeSeries

comptime AXES: List[String] = ["x", "y", "z", "w", "roll", "pitch", "yaw"]
comptime GUTTER = 132.0  # points: the lane titles and values, left of the plots
comptime AXIS_H = 20.0  # points: the time axis under the lanes
comptime GAP = 6.0


def family_of(name: String) -> String:
    """The family a column belongs to: joint_vel_3 → joint_vel, pos_x → pos, rot_yaw → rot, gripper → gripper."""
    var cut = name.rfind("_")
    if cut <= 0:
        return name
    var tail = String(name[byte = cut + 1 :])
    var axes = materialize[AXES]()
    var digits = tail.byte_length() > 0
    for b in tail.as_bytes():
        if b < UInt8(48) or b > UInt8(57):
            digits = False
    if digits or tail in axes:
        return String(name[byte=0:cut])
    return name


def member_of(name: String) -> String:
    """A column's name inside its family: joint_vel_3 → 3, pos_x → x; the whole name when it is a family of one."""
    var f = family_of(name)
    if f == name:
        return name
    return String(name[byte = f.byte_length() + 1 :])


def family_title(family: String) -> String:
    """A family in words: each word whole (vel → velocity, pos → position, rot → rotation, acc → acceleration)."""
    var out = String("")
    for w in family.split("_"):
        var word = String(w)
        if word == "vel":
            word = "velocity"
        elif word == "pos":
            word = "position"
        elif word == "rot":
            word = "rotation"
        elif word == "acc":
            word = "acceleration"
        elif word == "err":
            word = "error"
        out += (" " if out.byte_length() > 0 else "") + word
    if out.byte_length() == 0:
        return out^
    return String(out[byte=0:1]).upper() + String(out[byte=1:])


struct Lane(Copyable, Movable):
    var family: String
    var title: String
    var columns: List[Int]  # the series' columns drawn in it
    var lo: Float64
    var hi: Float64
    var limit: Float64  # a spec line at ±limit (0: none)

    def __init__(out self, family: String):
        self.family = family
        self.title = family_title(family)
        self.columns = List[Int]()
        self.lo = 0.0
        self.hi = 1.0
        self.limit = 0.0


@fieldwise_init
struct Mark(Copyable, Movable, ImplicitlyCopyable):
    var t: Float64
    var on: Bool
    var label: String


def lanes_of(series: TimeSeries, most: Int = 4) -> List[Lane]:
    """The series' families in column order, the first `most` of them."""
    var out = List[Lane]()
    for c in range(len(series.names)):
        var f = family_of(series.names[c])
        var at = -1
        for i in range(len(out)):
            if out[i].family == f:
                at = i
        if at < 0:
            if len(out) >= most:
                continue
            out.append(Lane(f))
            at = len(out) - 1
        out[at].columns.append(c)
    return out^


struct TelemetryChart(Copyable, Movable):
    var series: TimeSeries
    var lanes: List[Lane]
    var shown: List[List[Float64]]  # per series column, what is drawn (smoothed)
    var smoothing: Int
    var marks: List[Mark]
    var title: String

    def __init__(out self, var series: TimeSeries, most: Int = 4, smoothing: Int = 3):
        self.lanes = lanes_of(series, most)
        self.series = series^
        self.smoothing = smoothing
        self.shown = List[List[Float64]]()
        self.marks = List[Mark]()
        self.title = ""
        self._refresh()

    def _refresh(mut self):
        self.shown = List[List[Float64]]()
        for c in range(len(self.series.names)):
            self.shown.append(smooth(self.series.columns[c], self.smoothing))
        for ref lane in self.lanes:
            var all = List[Float64]()
            for c in lane.columns:
                for v in self.shown[c]:
                    all.append(v)
            if lane.limit > 0:
                all.append(lane.limit)
                all.append(-lane.limit)
            var r = span_of(all)
            var pad = (r[1] - r[0]) * 0.08
            lane.lo = r[0] - pad
            lane.hi = r[1] + pad

    def set_smoothing(mut self, window: Int):
        self.smoothing = max(window, 1)
        self._refresh()

    def limit(mut self, family: String, value: Float64):
        """A spec line at ±value across the lane of `family` (the lane widens to show it)."""
        for ref lane in self.lanes:
            if lane.family == family:
                lane.limit = value
        self._refresh()

    def mark_steps(mut self, column: String, on_above: Float64, off_below: Float64, on_label: String, off_label: String) -> Int:
        """Marks each moment `column` turns on and off (mojoui.signal.steps on the raw values); how many marks."""
        var i = self.series.index(column)
        if i < 0:
            return 0
        for s in steps(self.series.columns[i], on_above, off_below):
            self.marks.append(Mark(self.series.times[s.at], s.on, on_label if s.on else off_label))
        return len(self.marks)

    def duration(self) -> Tuple[Float64, Float64]:
        var n = self.series.rows()
        if n == 0:
            return (0.0, 1.0)
        var t1 = self.series.times[n - 1]
        return (self.series.times[0], t1 if t1 > self.series.times[0] else self.series.times[0] + 1.0)

    def seek_at(self, x: Float64, width: Float64) -> Float64:
        """The time under x (points from the chart's left edge), clamped to the recording."""
        var d = self.duration()
        var plot = max(width - GUTTER - 8.0, 1.0)
        var f = min(max((x - GUTTER) / plot, 0.0), 1.0)
        return d[0] + f * (d[1] - d[0])

    def value_text(self, c: Int, t: Float64) -> String:
        return fixed(self.series.at(self.series.names[c], t), 2)

    def describe(self, t: Float64) -> String:
        """At t: each lane's values ("Joint velocity 1 0.12, 2 -0.40, …; Gripper 0.63; …") and the marks so far."""
        var out = clock_text(t)
        for ref lane in self.lanes:
            out += "; " + lane.title
            for i in range(len(lane.columns)):
                var c = lane.columns[i]
                var m = member_of(self.series.names[c])
                out += (" " if i == 0 else ", ") + (m + " " if m != lane.family else String("")) + self.value_text(c, t)
        var said = List[String]()
        for m in self.marks:
            if m.t <= t + 1e-9:
                said.append(m.label + " at " + fixed(m.t, 2) + " s")
        if len(said) > 0:
            out += ". So far: " + ", ".join(said)
        return out^

    def draw(self, mut s: Surface, font: Font, pal: Palette, t: Float64):
        """The lanes stacked top to bottom over a time axis, the marks, the spec lines and the cursor at t."""
        var k = s.scale
        s.fill(pal.card)
        var w = Float64(s.width)
        var h = Float64(s.height)
        var n_lanes = len(self.lanes)
        if n_lanes == 0 or self.series.rows() < 2:
            font.draw(s, "No channels to draw", 12 * k, 22 * k, 13 * k, pal.ink2)
            return
        var d = self.duration()
        var left = GUTTER * k
        var right = w - 8 * k
        var plot_w = max(right - left, 1.0)
        var top = 4.0 * k
        var bottom = h - AXIS_H * k
        var lane_h = (bottom - top - GAP * k * Float64(n_lanes - 1)) / Float64(n_lanes)
        var cx = left + (min(max(t, d[0]), d[1]) - d[0]) / (d[1] - d[0]) * plot_w

        var t0 = d[0]
        var tspan = d[1] - d[0]
        var step = max(self.series.rows() // Int(max(plot_w / (1.5 * k), 1.0)), 1)  # (at most a point every 1.5 px)
        var colour_at = 0
        for li in range(n_lanes):
            ref lane = self.lanes[li]
            var y0 = top + Float64(li) * (lane_h + GAP * k)
            rect(s, left, y0, plot_w, lane_h, pal.raised, 6 * k)
            var span = lane.hi - lane.lo
            var lo = lane.lo
            if lane.lo < 0.0 and lane.hi > 0.0:  # the zero line
                line(s, left + 4 * k, (y0 + lane_h - (0.0 - lo) / span * lane_h), right - 4 * k, (y0 + lane_h - (0.0 - lo) / span * lane_h), 1.0 * k, pal.line)
            if lane.limit > 0:  # the spec, dashed, in the warning colour
                for sign in [1.0, -1.0]:
                    var yy = (y0 + lane_h - (sign * lane.limit - lo) / span * lane_h)
                    var x = left + 4 * k
                    while x < right - 4 * k:
                        line(s, x, yy, min(x + 6 * k, right - 4 * k), yy, 1.2 * k, with_alpha(pal.warn, 0.85))
                        x += 11 * k
                font.draw(s, "limit ±" + fixed(lane.limit, 2), right - 8 * k, (y0 + lane_h - (lane.limit - lo) / span * lane_h) + 13 * k, 11 * k, pal.warn, REGULAR, RIGHT)
            for m in self.marks:  # every lane shows when the gripper (or whatever) changed
                var mx = (left + (m.t - t0) / tspan * plot_w)
                line(s, mx, y0 + 3 * k, mx, y0 + lane_h - 3 * k, 1.0 * k, with_alpha(pal.accent if m.on else pal.ink3, 0.55))
            for ci in range(len(lane.columns)):
                var c = lane.columns[ci]
                var ink = pal.series[(colour_at + ci) % len(pal.series)] if len(pal.series) > 0 else pal.accent
                ref vals = self.shown[c]
                var px = (left + (self.series.times[0] - t0) / tspan * plot_w)
                var py = (y0 + lane_h - (vals[0] - lo) / span * lane_h)
                var i = step
                while i < len(vals):
                    var x = (left + (self.series.times[i] - t0) / tspan * plot_w)
                    var y = (y0 + lane_h - (vals[i] - lo) / span * lane_h)
                    line(s, px, py, x, y, 1.6 * k, ink)
                    px = x
                    py = y
                    i += step
                var last = len(vals) - 1
                if (last % step) != 0:
                    line(s, px, py, (left + (self.series.times[last] - t0) / tspan * plot_w), (y0 + lane_h - (vals[last] - lo) / span * lane_h), 1.6 * k, ink)
                var v = self.series.at(self.series.names[c], t)  # the value at the cursor: a dot on the line
                circle(s, cx, (y0 + lane_h - (min(max(v, lane.lo), lane.hi) - lo) / span * lane_h), 3.2 * k, ink)
            colour_at += len(lane.columns)
            # the title and the values at the cursor, in the gutter
            font.draw(s, lane.title, 8 * k, y0 + 15 * k, 12.5 * k, pal.ink, MEDIUM)
            var row = y0 + 31 * k
            var col = 0
            for ci in range(len(lane.columns)):
                if row > y0 + lane_h - 2 * k:
                    break
                var c = lane.columns[ci]
                var ink = pal.series[(colour_at - len(lane.columns) + ci) % len(pal.series)] if len(pal.series) > 0 else pal.accent
                var x = 8 * k + Float64(col) * 62 * k
                circle(s, x + 3 * k, row - 4 * k, 3 * k, ink)
                font.draw(s, self.value_text(c, t), x + 10 * k, row, 11 * k, pal.ink2, MONO)
                col += 1
                if col == 2:
                    col = 0
                    row += 15 * k
        # the time axis: a tick every few seconds
        var total = d[1] - d[0]
        var every = 1.0
        for cand in [1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0]:
            every = cand
            if total / cand <= plot_w / (90 * k):
                break
        var tick = d[0]
        while tick <= d[1] + 1e-9:
            var x = (left + (tick - t0) / tspan * plot_w)
            line(s, x, bottom + 1 * k, x, bottom + 5 * k, 1.0 * k, pal.line_strong)
            font.draw(s, clock_text(tick), x + 3 * k, bottom + 15 * k, 11 * k, pal.ink3)
            tick += every
        # the cursor: a soft glow and a line through every lane, the time in a pill at the top
        line(s, cx, top, cx, bottom, 7.0 * k, with_alpha(pal.accent, 0.16))
        line(s, cx, top, cx, bottom, 1.6 * k, pal.ink)
        var label = clock_text(t)
        var lw = font.measure(label, 11 * k, MONO) + 12 * k
        var lx = min(max(cx - lw / 2, left), right - lw)
        rect(s, lx, bottom + 2 * k, lw, 17 * k, pal.accent, 8.5 * k)
        font.draw(s, label, lx + 6 * k, bottom + 14.5 * k, 11 * k, pal.accent_ink, MONO)
        if trace_on():
            print("CURSOR: t=" + fixed(t, 3), flush=True)
