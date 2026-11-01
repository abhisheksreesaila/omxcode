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
from mojoui.files import file_stem
from mojoui.timeseries import TimeSeries, metric_label, metric_unit  # (they live with TimeSeries: the editor names its lanes with them too)
from mojoui.telemetrychart import TelemetryChart, Mark, family_of
from mojoui.logindex import KeyIndex
from mojoui.view import (View, Text, Button, Canvas, HStack, Spacer, Card, Segmented, HEADLINE, CAPTION, ICON_ONLY, CENTER,
                         PAN, TAP, PRESS, SET_TO, TONE_ACCENT)

comptime SCAN_MOST = 200_000  # a log this long (or shorter) may be scanned on the UI thread for a slice (a few ms)

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


def is_multichannel(series: TimeSeries) -> Bool:
    """A log whose channels come in families (joint_vel_1…7, pos_x/y/z): drawn as stacked lanes (mojoui.telemetrychart)
    rather than one column at a time."""
    for i in range(len(series.names)):
        for j in range(i + 1, len(series.names)):
            var f = family_of(series.names[i])
            if f != series.names[i] and f == family_of(series.names[j]):
                return True
    return False


def series_where(sheet: Sheet, key: String, value: String) raises -> Tuple[TimeSeries, List[Mark]]:
    """The rows of a log table whose `key` column reads `value` (one episode of a fleet's telemetry), as a TimeSeries in
    the log's order; every other text column's non-empty cells become marks (an event column: "close", "open"). Scans the
    log, so only a log of up to SCAN_MOST rows: a longer one raises (index it, mojoui.logindex, and use
    series_where_indexed)."""
    var kc = sheet.index(key)
    var tc = time_column(sheet)
    if kc < 0 or tc < 0:
        raise Error(("no column " + key) if kc < 0 else "no time column (t, time or seconds)")
    var n = sheet.rows()
    if n > SCAN_MOST:
        raise Error("the log has " + String(n) + " rows: slice it through its index of " + key)
    var keep = List[Int]()
    if sheet.kind(kc) == TEXT:
        var code = sheet.code_of(kc, value)
        if code >= 0:
            for r in range(n):
                if sheet.value(kc, r) == Int64(code) and sheet.alive(r) and not sheet.is_null(tc, r):
                    keep.append(r)
    else:
        for r in range(n):
            if sheet.alive(r) and sheet.plain_text(kc, r) == value and not sheet.is_null(tc, r):
                keep.append(r)
    return _series_of(sheet, kc, tc, keep)


def series_where_indexed(sheet: Sheet, key: String, value: String, index: KeyIndex) raises -> Tuple[TimeSeries, List[Mark]]:
    """series_where through a KeyIndex of `key` (built off the UI thread): the rows found in O(1), exactly that key's;
    raises when the index isn't of this log and key, or the log isn't grouped by it (never a guess)."""
    var span = _key_rows(sheet, key, value, index)
    var tc = time_column(sheet)
    if tc < 0:
        raise Error("no time column (t, time or seconds)")
    var keep = List[Int]()
    for r in range(span[0], span[0] + span[1]):
        if sheet.alive(r) and not sheet.is_null(tc, r):
            keep.append(r)
    return _series_of(sheet, sheet.index(key), tc, keep)


def _series_of(sheet: Sheet, kc: Int, tc: Int, keep: List[Int]) raises -> Tuple[TimeSeries, List[Mark]]:
    var times = List[Float64]()
    for r in keep:
        times.append(Float64(sheet.plain_text(tc, r).replace(",", "")))
    var ts = TimeSeries(times^)
    var marks = List[Mark]()
    for c in range(sheet.columns()):
        var k = sheet.kind(c)
        if c == tc or c == kc or k == BOOL or k == DATE:
            continue
        if k == TEXT:
            for i in range(len(keep)):
                var t = sheet.plain_text(c, keep[i])
                if t.byte_length() > 0:
                    marks.append(Mark(ts.times[i], t == "close" or t == "on" or t == "start", t))
            continue
        var values = List[Float64]()
        for r in keep:
            var s = sheet.plain_text(c, r).replace(",", "")
            values.append(Float64(s) if s.byte_length() > 0 else (values[len(values) - 1] if len(values) > 0 else 0.0))
        ts.add(_normal(sheet.name(c)), values^)
    return (ts^, marks^)


def _key_rows(sheet: Sheet, key: String, value: String, index: KeyIndex) raises -> Tuple[Int, Int]:
    """(first row, count) of `value` in a grouped, indexed log; raises when the index can't say."""
    var kc = sheet.index(key)
    if kc < 0 or index.column != key or index.rows != sheet.rows() or index.edits != sheet.edits() or index.problem != "" or sheet.kind(kc) != TEXT:
        raise Error("no index of " + key + " for this log")
    if not index.grouped:
        raise Error(key + "'s rows come in several runs: sort the log by " + key + " to slice it")
    var code = sheet.code_of(kc, value)
    return index.span_of(code) if code >= 0 else (-1, 0)


def last_off_mark(sheet: Sheet, key: String, value: String, index: KeyIndex) raises -> Tuple[Float64, Int, Float64]:
    """For one recording of an indexed log: the time and row of its last "off" event (a text cell that isn't close, on or
    start: a gripper opening), else (-1, -1); and the recording's last time. Reads only the time and text columns of its
    rows (a pack asks this per row: cheap, no TimeSeries)."""
    var span = _key_rows(sheet, key, value, index)
    var tc = time_column(sheet)
    var kc = sheet.index(key)
    var at = -1.0
    var row = -1
    var last = 0.0
    for r in range(span[0], span[0] + span[1]):
        if not sheet.alive(r) or sheet.is_null(tc, r):
            continue
        var t = Float64(sheet.plain_text(tc, r).replace(",", ""))
        last = t
        for c in range(sheet.columns()):
            if c == kc or sheet.kind(c) != TEXT:
                continue
            var w = sheet.plain_text(c, r)
            if w.byte_length() > 0 and not (w == "close" or w == "on" or w == "start"):
                at = t
                row = r
    return (at, row, last)


def row_words(sheet: Sheet, row: Int, most: Int = 16) -> String:
    """One row's numbers in words ("joint_vel_1 0.12, gripper 0.97, …"), the first `most` number columns."""
    var out = List[String]()
    for c in range(sheet.columns()):
        var k = sheet.kind(c)
        if k == TEXT or k == BOOL or k == DATE or len(out) >= most:
            continue
        out.append(sheet.name(c) + " " + sheet.plain_text(c, row))
    return ", ".join(out)


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
    var lanes: Optional[TelemetryChart]  # a multichannel log: stacked lanes instead of one column (is_multichannel)

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
        self.lanes = None
        if is_multichannel(self.series):
            self.lanes = TelemetryChart(self.series.copy())
            self.metric = 1  # (Smoothed)

    def mark(mut self, var marks: List[Mark]):
        """Events on a multichannel card's lanes (series_where's marks)."""
        if self.lanes:
            self.lanes.value().marks = marks^

    def limits(mut self, names: List[String], values: List[Float64]) -> Int:
        """Spec lines from a table of (channel, limit) rows: each named channel's lane gets ±its largest limit. How many
        names matched a channel."""
        if not self.lanes:
            return 0
        var n = 0
        for i in range(min(len(names), len(values))):
            if self.series.index(names[i]) >= 0:
                var f = family_of(names[i])
                var have = 0.0
                for ref lane in self.lanes.value().lanes:
                    if lane.family == f:
                        have = lane.limit
                if values[i] > have:
                    self.lanes.value().limit(f, values[i])
                n += 1
        return n

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
        if self.lanes:
            return self.lanes.value().describe(t)
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

    def video_for_log(self, name: String, videos: List[String]) -> String:
        """The video a log called `name` belongs to, among `videos` (oldest first: MediaCards.video_paths): the one whose
        file name ends the same way (telemetry_a ↔ drone_a) and has no log yet, else the newest with no log, else ""."""
        var best = String("")
        var most = 0
        for v in videos:
            var a = name.as_bytes()
            var b_text = file_stem(v)
            var b = b_text.as_bytes()
            var n = 0
            while n < len(a) and n < len(b) and a[len(a) - 1 - n] == b[len(b) - 1 - n]:
                n += 1
            if n > most and self.for_video(v) < 0:
                most = n
                best = v
        if best != "":
            return best^
        for i in range(len(videos) - 1, -1, -1):
            if self.for_video(videos[i]) < 0:
                return videos[i]
        return String("")

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
                        if self.cards[k].lanes:
                            self.seek_to = self.cards[k].lanes.value().seek_at(event.x, self.cards[k].chart_size[0])
                        else:
                            var cv = self.cards[k].chart(0.0)
                            self.seek_to = cv.seek_at(event.x, font, pal)
                        self.seek_card = k
                elif which == TK_METRIC:
                    self.cards[k].metric = max(event.number, 0)
                    if self.cards[k].lanes:  # (a multichannel card's switch: Raw or Smoothed)
                        self.cards[k].lanes.value().set_smoothing(1 if event.number == 0 else 3)
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
            if c.lanes:
                c.lanes.value().draw(s, font, pal, t)
                return
            var cv = c.chart(t)
            cv.draw(s, font, pal)
        else:
            c.map(t).draw(s, font, pal)

    def describe(self, canvas: Int, t: Float64) -> String:
        var k = self._card_of_canvas(canvas)
        if k < 0:
            return ""
        ref c = self.cards[k]
        if canvas == self.canvas(k) and c.lanes:
            return (c.name + ": " + String(len(c.lanes.value().lanes)) + " lanes over " + clock_text(c.lanes.value().duration()[1]) + ", in step with "
                    + c.video + "; at the playhead " + c.readout(t) + ". Set it to a time in seconds to move the video there.")
        if canvas == self.canvas(k):
            return (c.name + ": " + metric_label(c.column()) + " over " + clock_text(c.series.times[len(c.series.times) - 1] if c.series.rows() > 0 else 0.0)
                    + ", in step with " + c.video + "; at the playhead " + c.readout(t) + ". Set it to a time in seconds to move the video there.")
        return c.name + ": " + c.map(t).describe()

    def view(self, k: Int, version: Int) -> View:
        """Card k: a title bar (its name, the column switch, close) over the chart and, with positions, the map."""
        ref c = self.cards[k]
        var tag = c.name.replace("_", "-").replace(" ", "-").lower()
        var labels = List[String]()
        if c.lanes:
            labels = ["Raw", "Smoothed"]
        else:
            for ref n in c.metrics:
                labels.append(metric_label(n))
        var parts = List[View]()
        parts.append(Text(c.name, HEADLINE).tag("track-title").tooltip(c.note if c.note != "" else "A log in step with " + c.video))
        parts.append(Text(String(c.series.rows()) + " rows" + (" · " + String(len(c.series.names)) + " channels" if c.lanes else String("")), CAPTION).tone(TONE_ACCENT))
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
