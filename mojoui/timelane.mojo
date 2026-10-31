# mojoui.timelane: one measure of a log drawn under a video, on the video's clock, with the video's playhead as its
# cursor (goal 41 M9: a time link only paints; a real as-of join waits for a question that needs it). A video card shows
# it (mojoui.mediacard.MediaCards.show_lane) once a log is linked to it by time (mojoui.links LINK_TIME).
#
#   var lane = TimeLane.of("sensor_log", series, "speed", offset=3.4)   # the log's t = the video's t + offset
#   draw():  lane.draw(surface, pal, t, duration)                          # t: the video's time; prints CURSOR: t=… when tracing
#   lane.value_at(t)                                                       # the measure at the video's time t

from mojoui.canvas import Surface
from mojoui.charts import fixed
from mojoui.draw import rect, line
from mojoui.clock import trace_on
from mojoui.theme import Palette, mix
from mojoui.timeseries import TimeSeries, metric_label, metric_unit


struct TimeLane(Copyable, Movable):
    var name: String  # the log's card ("sensor_log")
    var column: String  # its measure ("speed")
    var times: List[Float64]  # on the video's clock
    var values: List[Float64]
    var offset: Float64  # the log's t = the video's t + offset

    def __init__(out self, name: String, column: String, var times: List[Float64], var values: List[Float64], offset: Float64):
        self.name = name
        self.column = column
        self.times = times^
        self.values = values^
        self.offset = offset

    @staticmethod
    def of(name: String, series: TimeSeries, column: String, offset: Float64) -> TimeLane:
        """The log's `column` on the video's clock (each of its times minus `offset`)."""
        var ts = List[Float64]()
        for t in series.times:
            ts.append(t - offset)
        return TimeLane(name, column, ts^, series.column(column), offset)

    def label(self) -> String:
        var unit = metric_unit(self.column)
        return self.name + " · " + metric_label(self.column) + (" (" + unit + ")" if unit != "" else String(""))

    def value_at(self, t: Float64) -> Float64:
        """The measure at the video's time t (the nearest earlier sample; the first before it starts)."""
        if len(self.times) == 0:
            return 0.0
        var lo = 0
        var hi = len(self.times) - 1
        if t <= self.times[0]:
            return self.values[0]
        while lo < hi:
            var mid = (lo + hi + 1) // 2
            if self.times[mid] <= t:
                lo = mid
            else:
                hi = mid - 1
        return self.values[lo]

    def line(self) -> String:
        """The trace line when it's shown: "LANE: sensor_log speed under clip.mp4 (log t = video t + 3.4 s), 381 samples"."""
        return ("LANE: " + self.name + " " + self.column + " (log t = video t " + ("+ " if self.offset >= 0 else "- ") + fixed(abs(self.offset), 3)
                + " s), " + String(len(self.times)) + " samples")

    def draw(self, mut s: Surface, pal: Palette, t: Float64, duration: Float64):
        """The measure as a line across the lane (0 … duration on the video's clock), the part outside the log left blank,
        and the playhead: the same instant the video shows."""
        var k = s.scale
        s.fill(pal.card)
        var w = Float64(s.width)
        var h = Float64(s.height)
        rect(s, 0, 0, w, h, pal.raised, 5 * k)
        if len(self.times) < 2 or duration <= 0:
            return
        var lo = self.values[0]
        var hi = self.values[0]
        for v in self.values:
            lo = min(lo, v)
            hi = max(hi, v)
        if hi <= lo:
            hi = lo + 1.0
        var pad = 4.0 * k
        var ink = mix(pal.raised, pal.accent, 0.8)
        var px = -1.0
        var py = 0.0
        var step = max(len(self.times) // Int(max(w / 2.0, 1.0)), 1)  # (at most a point every two pixels)
        var i = 0
        while i < len(self.times):
            var x = self.times[i] / duration * w
            var y = h - pad - (self.values[i] - lo) / (hi - lo) * (h - 2 * pad)
            if 0.0 <= x and x <= w:
                if px >= 0:
                    line(s, px, py, x, y, 1.5 * k, ink)
                px = x
                py = y
            i += step
        var cx = min(max(t / duration, 0.0), 1.0) * w
        line(s, cx, 0, cx, h, 2.0 * k, pal.ink)
        if trace_on():
            print("CURSOR: t=" + fixed(t, 3), flush=True)
