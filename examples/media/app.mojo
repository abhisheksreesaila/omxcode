# Media: a drone's inspection flight, the video with its telemetry beside it (goal 39 M2). The framework's Player plays the
# footage; a line chart of the telemetry carries a cursor at the video's time (tap or drag the chart to seek); a readout shows
# the telemetry row under it. Composed from components only: mojoui.player, mojoui.timeseries, mojoui.csvio, ChartView.
#
# The footage and telemetry are generated (scripts/media_data.py): $G39_MEDIA names the folder (default build/g39/media),
# which holds drone_a.mp4 and telemetry_a.csv. Space plays and pauses, ←/→ step a frame (click the picture first).

from std.os import getenv

from mojoui import (
    App, Event, View, Surface, VStack, HStack, Text, Canvas, Segmented, Card, Grid, Spacer, TITLE, HEADLINE, CAPTION, NO_MSG, START, CENTER,
)
from mojoui.view import PAN, TAP, PRESS, SPACE_M, SPACE_L
from mojoui.chartview import ChartView
from mojoui.charts import fixed, fitted_floor
from mojoui.csvio import read_csv
from mojoui.player import Player, clock_text
from mojoui.sheet import Sheet
from mojoui.text import Font
from mojoui.theme import Theme, Palette
from mojoui.timeseries import TimeSeries
from themes.liquid import liquid, liquid_palette

comptime METRIC = 1
comptime CHART_GESTURE = 2
comptime CHART = 1
comptime PLAYER_MSG = 100  # the Player owns messages 100 … 104 and canvases 100, 101
comptime PLAYER_CANVAS = 100
comptime PAD = 28  # (points) the screen's margin, the gap between picture and side column, the side column's width
comptime GAP = 24
comptime SIDE = 400
comptime NARROW = 760  # a window narrower than this (points) stacks the screen: picture, chart, readout

comptime METRICS: List[String] = ["Altitude", "Speed", "Battery"]  # (what the chart can show, and its columns in the CSV)
comptime COLUMNS: List[String] = ["alt_m", "speed_ms", "battery_pct"]


def telemetry(path: String) raises -> TimeSeries:
    """telemetry_a.csv (t, lat, lon, alt_m, heading_deg, speed_ms, battery_pct) as a TimeSeries, read with mojoui.csvio."""
    var imp = read_csv(path)
    var sheet = Sheet(imp.table, False)
    var times = List[Float64]()
    for r in range(sheet.rows()):
        times.append(Float64(sheet.plain_text(sheet.index("t"), r)))
    var ts = TimeSeries(times^)
    for c in imp.columns:
        if c.name != "t":
            var values = List[Float64]()
            var col = sheet.index(c.name)
            for r in range(sheet.rows()):
                values.append(Float64(sheet.plain_text(col, r)))
            ts.add(c.name, values^)
    return ts^


struct Main(App):
    var player: Optional[Player]
    var series: TimeSeries
    var problem: String
    var metric: Int
    var width: Int  # the window's width in points
    var theme_: Theme
    var pal: Palette
    var font: Font
    var file: String

    def __init__(out self):
        var folder = getenv("G39_MEDIA", "build/g39/media")
        self.file = "drone_a.mp4"
        self.series = TimeSeries(List[Float64]())
        self.problem = ""
        self.player = None
        self.metric = 0
        self.width = 1280
        self.pal = liquid_palette()
        self.theme_ = liquid(self.pal)
        self.font = Font()
        try:
            self.player = Player(folder + "/" + self.file, PLAYER_MSG, PLAYER_CANVAS)
            self.series = telemetry(folder + "/telemetry_a.csv")
        except e:
            self.problem = String(e)

    def title(self) -> String:
        return "Media"

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 800)

    def theme(self) -> Theme:
        return self.theme_.copy()

    def resize(mut self, width: Int, height: Int):
        self.width = width

    def describe(self, canvas: Int, first: Int, count: Int) -> String:
        if canvas == PLAYER_CANVAS + 1 and self.player:
            return self.player.value().describe()
        return ""

    # ---------- the chart ----------

    def chart(self) -> ChartView:
        """The telemetry line chosen, with the cursor at the video's time."""
        var labels = List[String]()
        for i in range(self.series.rows()):
            labels.append(clock_text(self.series.times[i]) if i % 50 == 0 else "")
        var cv = ChartView.line(materialize[METRICS]()[self.metric], labels^, self.series.column(materialize[COLUMNS]()[self.metric]))
        cv.money = False
        cv.xs = self.series.times.copy()
        cv.floor = fitted_floor(cv.values)
        if self.player:
            cv = cv^.with_cursor(self.player.value().state.t())
        return cv^

    def t(self) -> Float64:
        return self.player.value().state.t() if self.player else 0.0

    # ---------- events ----------

    def update(mut self, event: Event):
        if self.player and self.player.value().update(event):
            return
        if event.message == METRIC:
            self.metric = event.number
        elif event.message == CHART_GESTURE and self.player:
            if event.number == PRESS or event.number == PAN or event.number == TAP:
                var cv = self.chart()
                self.player.value().state.seek(cv.seek_at(event.x, self.font, self.pal))

    # ---------- drawing ----------

    def draw(mut self, canvas: Int, mut s: Surface):
        if canvas == CHART:
            var cv = self.chart()
            cv.draw(s, self.font, self.pal)
        elif self.player and self.player.value().draws(canvas):
            self.player.value().draw(canvas, s, self.pal.page, self.pal)

    # ---------- the screen ----------

    def stat(self, label: String, value: String) -> View:
        return VStack(Text(label, style=CAPTION), Text(value, style=HEADLINE), spacing=2).align(START)

    def readout(self) -> View:
        var row = self.series.row_at(self.t())
        var items = List[View]()
        items.append(self.stat("Altitude", fixed(self.series.value("alt_m", row), 1) + " m"))
        items.append(self.stat("Speed", fixed(self.series.value("speed_ms", row), 1) + " m/s"))
        items.append(self.stat("Battery", fixed(self.series.value("battery_pct", row), 0) + " %"))
        items.append(self.stat("Heading", fixed(self.series.value("heading_deg", row), 0) + "°"))
        items.append(self.stat("Latitude", fixed(self.series.value("lat", row), 5) + "°"))
        items.append(self.stat("Longitude", fixed(self.series.value("lon", row), 5) + "°"))
        return Card(Grid(items^, 3, spacing=16), spacing=0).fill()

    def telemetry_card(self) -> View:
        var head = HStack(Text("Telemetry", style=HEADLINE), Spacer(), Segmented(materialize[METRICS](), self.metric, on_select=METRIC), spacing=12).align(CENTER).fill()
        var plot = Canvas(CHART, self.player.value().state.frame * 4 + self.metric, on_gesture=CHART_GESTURE).fill().grow().tag("telemetry")
        return Card(head^, plot^, spacing=8).fill()

    def view(self) -> View:
        if not self.player:
            return VStack(Text("Media", style=TITLE), Text(self.problem, style=CAPTION), spacing=SPACE_M).padding(24)
        var header = VStack(Text("Inspection flight", style=TITLE), Text(self.file + " · telemetry at 10 Hz, in step with the picture", style=CAPTION), spacing=2).align(START).fill()
        if self.width < NARROW:
            var picture = self.player.value().view(self.width - 32)
            return VStack(header^, picture^, self.telemetry_card().height(210), self.readout(), spacing=SPACE_M).padding(16).grow().fill()
        var wide = self.width - 2 * PAD - SIDE - GAP  # the picture's width: what the side column leaves
        var picture = self.player.value().view(wide)
        var side = VStack(self.telemetry_card().grow(), self.readout(), spacing=GAP).width(SIDE).height(self.player.value().height_for(wide) + 68)
        return VStack(header^, HStack(picture^, side^, spacing=GAP).align(START).fill(), spacing=SPACE_L).padding(PAD).grow().fill().justify(CENTER)
