# mojoui.trackcard: a recording's log (a drone's telemetry, a car's GPS, a sensor run) as a card on a page, in step with a
# video (goal 39 M8). A generic component: any app with a Board puts one beside a MediaCards video; the card shows a line
# chart of one of the log's columns with a time cursor at the video's playhead (tap or drag the chart to seek it) and,
# when the log has positions, a map (mojoui.mapview) of the route with the playhead as a dot and places marked on it.
# Each card owns a block of messages and two canvases, allocated when it is added.
#
#   if is_track(sheet): var ts = series_from_sheet(sheet)          # a table with a time column and numbers (lat, lon: a map)
#   var tracks = TrackCards(msg_base=4200, canvas_base=250, most=8) # messages 4200 … 4200 + 8·TRACK_MESSAGES, canvases 250 … 265
#   var k = tracks.add("telemetry_a", ts^, video_path, x, y, w, h)   # bound to the video at video_path (its card's player)
#   tracks.cards[k].marks = …                                        # mapview marks: assets, findings
#   update():   if tracks.update(event, font, pal): tracks.seek_card, tracks.seek_to (seconds) say where to move its video
#   view():     tracks.view(k, version)                              # version: change it when the video's frame changes
#   draw():     if tracks.draws(canvas): tracks.draw(canvas, surface, font, pal, t)   # t: the bound video's time
#   describe(): tracks.describe(canvas, t)                           # the row at t, and the map, for an agent
#
# For an agent the chart is a settable control: its tool takes a time in seconds (the bound video seeks there). The
# chart prints `CURSOR: t=…` each time it draws its cursor when tracing (mojoui.charts), so a check can hold the cursor
# against the video's `PLAYER: t=` lines.

from mojoui.app import Event
from mojoui.canvas import Surface
from mojoui.chartview import ChartView
from mojoui.charts import fixed, fitted_floor
from mojoui.mapview import MapView, MapMark, MARK_PLACE, MARK_FINDING
from mojoui.player import clock_text
from mojoui.sheet import Sheet, TEXT, BOOL, DATE
from mojoui.text import Font
from mojoui.theme import Palette
from mojoui.timeseries import TimeSeries
from mojoui.view import (View, Text, Button, Canvas, HStack, Spacer, Card, Segmented, HEADLINE, CAPTION, ICON_ONLY, CENTER,
                         PAN, TAP, PRESS, SET_TO, TONE_ACCENT)

comptime TRACK_MESSAGES = 4  # a card's block: its chart's gestures (0), the column picked (1), close (2), its map's gestures (3)
comptime TK_CHART = 0
comptime TK_METRIC = 1
comptime TK_CLOSE = 2
comptime TK_MAP = 3
comptime TRACK_CANVASES = 2  # the chart, the map
comptime MAX_METRICS = 4  # columns offered in the card's switch
comptime TIME_NAMES: List[String] = ["t", "time", "seconds", "time_s", "t_s"]


def _normal(name: String) -> String:
    """A log's column under the name mojoui.geo reads (latitude → lat, longitude/lng → lon, alt/altitude → alt_m,
    heading → heading_deg); other names as they are, lower case."""
    var n = name.lower()
    if n == "latitude":
        return String("lat")
    if n == "longitude" or n == "lng":
        return String("lon")
    if n == "alt" or n == "altitude":
        return String("alt_m")
    if n == "heading" or n == "yaw":
        return String("heading_deg")
    return n^


def time_column(sheet: Sheet) -> Int:
    """The log's time column (t, time, seconds…), else -1."""
    var names = materialize[TIME_NAMES]()
    for c in range(sheet.columns()):
        var n = sheet.name(c).lower()
        for ref want in names:
            if n == want:
                return c
    return -1


def is_track(sheet: Sheet) -> Bool:
    """A table that is a log of positions over time: a time column and latitude and longitude."""
    if time_column(sheet) < 0:
        return False
    var lat = False
    var lon = False
    for c in range(sheet.columns()):
        var n = _normal(sheet.name(c))
        lat = lat or n == "lat"
        lon = lon or n == "lon"
    return lat and lon


def series_from_sheet(sheet: Sheet) raises -> TimeSeries:
    """The table as a TimeSeries: its time column, then every number column (positions under mojoui.geo's names).
    Rows in the table's order; a row with no time is left out."""
    var tc = time_column(sheet)
    if tc < 0:
        raise Error("no time column (t, time or seconds)")
    var keep = List[Int]()
    for r in range(sheet.rows()):
        if sheet.alive(r) and not sheet.is_null(tc, r):
            keep.append(r)
    var times = List[Float64]()
    for r in keep:
        times.append(Float64(sheet.plain_text(tc, r).replace(",", "")))
    var ts = TimeSeries(times^)
    for c in range(sheet.columns()):
        var k = sheet.kind(c)
        if c == tc or k == TEXT or k == BOOL or k == DATE:
            continue
        var values = List[Float64]()
        for r in keep:
            var s = sheet.plain_text(c, r).replace(",", "")
            values.append(Float64(s) if s.byte_length() > 0 else (values[len(values) - 1] if len(values) > 0 else 0.0))
        ts.add(_normal(sheet.name(c)), values^)
    return ts^


def metric_label(name: String) -> String:
    """A column's name as a person says it: alt_m → Altitude, speed_ms → Speed, battery_pct → Battery, else its words."""
    if name == "alt_m":
        return String("Altitude")
    if name.startswith("speed"):
        return String("Speed")
    if name.startswith("battery"):
        return String("Battery")
    if name == "heading_deg":
        return String("Heading")
    var words = name.replace("_", " ")
    if words.byte_length() == 0:
        return words^
    return String(words[byte=0:1]).upper() + String(words[byte=1:])


def metric_unit(name: String) -> String:
    if name.endswith("_m"):
        return String("m")
    if name.endswith("_ms"):
        return String("m/s")
    if name.endswith("_pct"):
        return String("%")
    if name.endswith("_deg"):
        return String("°")
    return String("")


struct TrackCard(Movable):
    var name: String
    var series: TimeSeries
    var video: String  # the bound video's path ("" none)
    var metrics: List[String]  # the columns the switch offers (not positions)
    var metric: Int
    var marks: List[MapMark]
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var slot: Int
    var chart_size: Tuple[Float64, Float64]  # points, from the chart's last draw (taps)
    var note: String

    def __init__(out self, name: String, var series: TimeSeries, video: String, slot: Int, x: Int, y: Int, w: Int, h: Int):
        self.name = name
        self.metrics = List[String]()
        for ref n in series.names:
            if n != "lat" and n != "lon" and len(self.metrics) < MAX_METRICS:
                self.metrics.append(n)
        self.series = series^
        self.video = video
        self.metric = 0
        self.marks = List[MapMark]()
        self.slot = slot
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.chart_size = (400.0, 200.0)
        self.note = ""

    def has_map(self) -> Bool:
        return self.series.index("lat") >= 0 and self.series.index("lon") >= 0

    def column(self) -> String:
        return self.metrics[min(self.metric, len(self.metrics) - 1)] if len(self.metrics) > 0 else String("")

    def chart(self, t: Float64) -> ChartView:
        """The chosen column over time, with the cursor at t."""
        var col = self.column()
        var labels = List[String]()
        var step = max(self.series.rows() // 5, 1)
        for i in range(self.series.rows()):
            labels.append(clock_text(self.series.times[i]) if i % step == 0 else "")
        var unit = metric_unit(col)
        var cv = ChartView.line(metric_label(col) + (" (" + unit + ")" if unit != "" else String("")), labels^, self.series.column(col))
        cv.money = False
        cv.xs = self.series.times.copy()
        cv.floor = fitted_floor(cv.values)
        cv.size = self.chart_size
        return cv^.with_cursor(t)

    def map(self, t: Float64) -> MapView:
        var m = MapView(self.series.column("lat"), self.series.column("lon"))
        m.marks = self.marks.copy()
        if self.series.rows() > 0:
            var b = self.series.bracket(t)
            m.at(self.series.at("lat", t), self.series.at("lon", t), b[0] + 1)
        return m^

    def readout(self, t: Float64) -> String:
        """The row at t, in words: "0:12.5 · Altitude 60.2 m · Speed 8.0 m/s · 52.01035, 5.12041"."""
        var out = clock_text(t)
        for ref n in self.metrics:
            var unit = metric_unit(n)
            out += " · " + metric_label(n) + " " + fixed(self.series.at(n, t), 1) + (" " + unit if unit != "" else String(""))
        if self.has_map():
            out += " · " + fixed(self.series.at("lat", t), 5) + ", " + fixed(self.series.at("lon", t), 5)
        return out^


struct TrackCards(Movable, Sized):
    var cards: List[TrackCard]
    var msg_base: Int
    var canvas_base: Int
    var most: Int
    var closed: Int  # the card the last update() removed (its index then), else -1
    var seek_card: Int  # the card whose chart asked its video to seek in the last update(), else -1
    var seek_to: Float64  # where (seconds)

    def __init__(out self, msg_base: Int, canvas_base: Int, most: Int = 8):
        self.cards = List[TrackCard]()
        self.msg_base = msg_base
        self.canvas_base = canvas_base
        self.most = most
        self.closed = -1
        self.seek_card = -1
        self.seek_to = 0.0

    def __len__(self) -> Int:
        return len(self.cards)

    def _free_slot(self) -> Int:
        for s in range(self.most):
            var used = False
            for k in range(len(self.cards)):
                if self.cards[k].slot == s:
                    used = True
            if not used:
                return s
        return -1

    def add(mut self, name: String, var series: TimeSeries, video: String, x: Int, y: Int, w: Int, h: Int) raises -> Int:
        """A card for the log at (x, y), w × h points, bound to the video at `video`; its index. A name already on the
        page is replaced in place."""
        var at = self.find(name)
        if at >= 0:
            var slot = self.cards[at].slot
            var px = self.cards[at].x
            var py = self.cards[at].y
            var pw = self.cards[at].w
            var ph = self.cards[at].h
            self.cards[at] = TrackCard(name, series^, video, slot, px, py, pw, ph)
            return at
        var slot = self._free_slot()
        if slot < 0:
            raise Error("A page holds up to " + String(self.most) + " logs: close one first")
        self.cards.append(TrackCard(name, series^, video, slot, x, y, w, h))
        return len(self.cards) - 1

    def find(self, name: String) -> Int:
        for k in range(len(self.cards)):
            if self.cards[k].name == name:
                return k
        return -1

    def for_video(self, path: String) -> Int:
        """The card bound to the video at `path`, else -1."""
        for k in range(len(self.cards)):
            if self.cards[k].video == path:
                return k
        return -1

    def remove(mut self, k: Int):
        if 0 <= k < len(self.cards):
            _ = self.cards.pop(k)

    def clear(mut self):
        self.cards = List[TrackCard]()

    def msg(self, k: Int) -> Int:
        return self.msg_base + self.cards[k].slot * TRACK_MESSAGES

    def canvas(self, k: Int) -> Int:
        return self.canvas_base + self.cards[k].slot * TRACK_CANVASES

    def owns(self, message: Int) -> Bool:
        return self.msg_base <= message < self.msg_base + self.most * TRACK_MESSAGES

    def update(mut self, event: Event, font: Font, pal: Palette) -> Bool:
        """True when `event` was a card's: a tap, drag or set time on its chart (seek_card, seek_to: move its video
        there), a column picked, or its close (closed)."""
        self.closed = -1
        self.seek_card = -1
        if not self.owns(event.message):
            return False
        for k in range(len(self.cards)):
            var m0 = self.msg(k)
            if m0 <= event.message < m0 + TRACK_MESSAGES:
                var which = event.message - m0
                if which == TK_CHART:
                    if event.number == SET_TO:
                        try:
                            self.seek_to = Float64(event.text)
                            self.seek_card = k
                        except:
                            pass
                    elif event.number == PRESS or event.number == PAN or event.number == TAP:
                        var cv = self.cards[k].chart(0.0)
                        self.seek_to = cv.seek_at(event.x, font, pal)
                        self.seek_card = k
                elif which == TK_METRIC:
                    self.cards[k].metric = max(event.number, 0)
                elif which == TK_CLOSE:
                    self.remove(k)
                    self.closed = k
                return True
        return True

    def _card_of_canvas(self, canvas: Int) -> Int:
        for k in range(len(self.cards)):
            var c0 = self.canvas(k)
            if c0 <= canvas < c0 + TRACK_CANVASES:
                return k
        return -1

    def draws(self, canvas: Int) -> Bool:
        return self._card_of_canvas(canvas) >= 0

    def draw(mut self, canvas: Int, mut s: Surface, font: Font, pal: Palette, t: Float64):
        var k = self._card_of_canvas(canvas)
        if k < 0:
            return
        ref c = self.cards[k]
        if canvas == self.canvas(k):
            c.chart_size = (s.points_width(), s.points_height())
            var cv = c.chart(t)
            cv.draw(s, font, pal)
        else:
            c.map(t).draw(s, font, pal)

    def describe(self, canvas: Int, t: Float64) -> String:
        var k = self._card_of_canvas(canvas)
        if k < 0:
            return ""
        ref c = self.cards[k]
        if canvas == self.canvas(k):
            return (c.name + ": " + metric_label(c.column()) + " over " + clock_text(c.series.times[len(c.series.times) - 1] if c.series.rows() > 0 else 0.0)
                    + ", in step with " + c.video + "; at the playhead " + c.readout(t) + ". Set it to a time in seconds to move the video there.")
        return c.name + ": " + c.map(t).describe()

    def view(self, k: Int, version: Int) -> View:
        """Card k: a title bar (its name, the column switch, close) over the chart and, with positions, the map."""
        ref c = self.cards[k]
        var tag = c.name.replace("_", "-").replace(" ", "-").lower()
        var labels = List[String]()
        for ref n in c.metrics:
            labels.append(metric_label(n))
        var parts = List[View]()
        parts.append(Text(c.name, HEADLINE).tag("track-title").tooltip(c.note if c.note != "" else "A log in step with " + c.video))
        parts.append(Text(String(c.series.rows()) + " rows", CAPTION).tone(TONE_ACCENT))
        parts.append(Spacer())
        if len(labels) > 1:
            parts.append(Segmented(labels, min(c.metric, len(labels) - 1), self.msg(k) + TK_METRIC).tag(tag + "-column"))
        parts.append(Button("Remove", self.msg(k) + TK_CLOSE, ICON_ONLY, icon="close").tag("close-log-" + tag).tooltip("Close " + c.name))
        var head = HStack(parts^, spacing=8).fill().align(CENTER).height(36)
        var duration = c.series.times[len(c.series.times) - 1] if c.series.rows() > 0 else 0.0
        var chart = (Canvas(self.canvas(k), version, on_gesture=self.msg(k) + TK_CHART).fill().grow().tag(tag + "-chart")
                     .settable("seconds", 0.0, duration).tooltip("Tap or drag to move the video there; set a time in seconds"))
        if not c.has_map():
            return Card(head^, chart^, spacing=4)
        var map_w = max(min(c.w // 2 - 6, c.h - 52), 160)  # (the map as tall as the card allows, up to half its width)
        var map = Canvas(self.canvas(k) + 1, version, on_gesture=self.msg(k) + TK_MAP).width(map_w).fill().tag(tag + "-map").tooltip("The route, the places found on it, and where the video is now")
        return Card(head^, HStack(chart^, map^, spacing=12).fill().grow(), spacing=4)
