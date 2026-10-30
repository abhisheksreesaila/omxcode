# Media: a drone's inspection flight, the video with its telemetry beside it (goal 39 M2). The framework's Player plays the
# footage; a line chart of the telemetry carries a cursor at the video's time (tap or drag the chart to seek); a readout shows
# the telemetry row under it. Composed from components only: mojoui.player, mojoui.timeseries, mojoui.csvio, ChartView.
#
# The footage and telemetry are generated (scripts/media_data.py): $G39_MEDIA names the folder (default build/g39/media),
# which holds drone_a.mp4 and telemetry_a.csv. Space plays and pauses, ←/→ step a frame (click the picture first).
#
# Edit (goal 39 M11) opens the framework's MediaTimeline on the same footage: the filmstrip, the telemetry as line lanes
# (altitude, speed) and the defects the GPU analysis finds (a background job) as a lane the sentence cuts by.
# G39_CLIP=warehouse opens the dock camera in the editor instead: pallets, faces and shipment IDs from its analysis.

from std.os import getenv

from mojoui import (
    App, Event, View, Surface, VStack, HStack, Text, Canvas, Segmented, Card, Grid, Spacer, Button, TITLE, HEADLINE, CAPTION, NO_MSG, START, CENTER,
)
from mojoui.view import PAN, TAP, PRESS, SPACE_M, SPACE_L
from mojoui.chartview import ChartView
from mojoui.charts import fixed, fitted_floor
from mojoui.csvio import read_csv
from mojoui.player import Player, clock_text
from mojoui.mediatimeline import MediaTimeline, value_lane, markers_from_table, LANE_MARKERS
from mojoui.mediatimeline_jobs import TimelineFeed, AnalyseJob
from mojoui.jobs import start_ui_job
from mojoui.videotable import VideoTable
from mojoui.videoexport import flagged_captions, read_csv_map
from mojoui.vision_presets import drone_analyzer, drone_ranges, DRONE_CELL, warehouse_analyzer, warehouse_ranges, WAREHOUSE_CELL
from mojoui.view import PROMINENT
from omxcore import Job, JOB_RUNNING
from mojoui.sheet import Sheet
from mojoui.text import Font
from mojoui.theme import Theme, Palette
from mojoui.timeseries import TimeSeries
from themes.liquid import liquid, liquid_palette

comptime METRIC = 1
comptime CHART_GESTURE = 2
comptime EDIT = 3  # opens the editor
comptime JOBS = 4  # a background job ended (App.jobs_message)
comptime EDITOR_MSG = 300  # the editor owns messages 300 … 363 and canvases 300 … 302
comptime EDITOR_CANVAS = 300
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
    var height: Int
    var theme_: Theme
    var pal: Palette
    var font: Font
    var file: String
    var folder: String
    var warehouse: Bool  # G39_CLIP=warehouse: the dock camera, straight into the editor
    var editor: Optional[MediaTimeline]
    var feed: TimelineFeed
    var analysis: Optional[Job[VideoTable]]

    def __init__(out self):
        var folder = getenv("G39_MEDIA", "build/g39/media")
        self.folder = folder
        self.warehouse = getenv("G39_CLIP") == "warehouse"
        self.file = "warehouse.mp4" if self.warehouse else "drone_a.mp4"
        self.editor = None
        self.feed = TimelineFeed()
        self.analysis = None
        self.series = TimeSeries(List[Float64]())
        self.problem = ""
        self.player = None
        self.metric = 0
        self.width = 1280
        self.height = 800
        self.pal = liquid_palette()
        self.theme_ = liquid(self.pal)
        self.font = Font()
        try:
            self.player = Player(folder + "/" + self.file, PLAYER_MSG, PLAYER_CANVAS)
            if not self.warehouse:
                self.series = telemetry(folder + "/telemetry_a.csv")
        except e:
            self.problem = String(e)
        if self.warehouse and self.player:
            self.open_editor()

    def title(self) -> String:
        return "Media"

    def window_size(self) -> Tuple[Int, Int]:
        return (1280, 800)

    def theme(self) -> Theme:
        return self.theme_.copy()

    def resize(mut self, width: Int, height: Int):
        self.width = width
        self.height = height
        if self.editor:
            self.editor.value().resize(width - 40, height - 32)  # (less the editor's margins)

    def jobs_message(self) -> Int:
        return JOBS

    def describe(self, canvas: Int, first: Int, count: Int) -> String:
        if self.editor and self.editor.value().draws(canvas):
            return self.editor.value().describe()
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

    def open_editor(mut self):
        """The editor on the same footage, where the player was (a recording not yet watched opens mid-way, so a split
        can start straight away); its lanes: the telemetry, then what the analysis finds."""
        try:
            var ed = MediaTimeline(self.folder + "/" + self.file, EDITOR_MSG, EDITOR_CANVAS)
            var t = self.t()
            ed.seek(t if t > 0 else ed.project.duration() / 2)
            if self.warehouse:
                ed.facts = "Dock 3 · " + ed.facts + " · analysing…"
                self.analysis = start_ui_job(AnalyseJob(ed.path(), warehouse_analyzer(), warehouse_ranges(), WAREHOUSE_CELL))
            else:
                ed.facts = "Inspection flight · " + ed.facts + " · analysing…"
                ed.add_lane(value_lane("Altitude", self.series, "alt_m", "m"))
                ed.add_lane(value_lane("Speed", self.series, "speed_ms", "m/s"))
                self.analysis = start_ui_job(AnalyseJob(ed.path(), drone_analyzer(), drone_ranges(), DRONE_CELL))
            ed.resize(self.width - 40, self.height - 32)
            self.editor = ed^
            if self.player:
                self.player.value().state.pause()
            self.feed.poll(self.editor.value())
        except e:
            self.problem = String(e)

    def analysed(mut self):
        """The analysis job ended: its rows become the editor's lanes and the sentence's choices."""
        if not self.analysis or self.analysis.value().poll() == JOB_RUNNING or not self.editor:
            return
        var job = self.analysis.take()
        try:
            var table = job.result()
            ref ed = self.editor.value()
            var base = ed.facts.replace(" · analysing…", "")
            if self.warehouse:
                var names = read_csv_map(self.folder + "/shipments.csv", "pallet_code", "shipment")
                var captions = flagged_captions(table, "pallet", names)
                ed.use_rows(table^, blur_kind="face", blur_noun="faces", object_kind="pallet", object_label="Pallets", flag_word="damaged")
                ed.use_captions(captions^, "shipment ID")
                var lane = ed.lanes[0].copy()
                ed.facts = base + " · analysed: " + String(lane.markers()) + " pallets, " + String(lane.flagged()) + " damaged"
            else:
                var defects = markers_from_table(table, "defect", "Defects", gap=15)
                for i in range(len(defects.flags)):
                    defects.flags[i] = True  # (a scorch mark is what the inspection is for: the warning tone)
                var n = defects.markers()
                ed.add_lane(defects^)
                ed.facts = base + " · analysed: " + String(n) + " defect sightings"
            ed.version += 1
        except e:
            self.editor.value().status = "Analysis failed: " + String(e)

    def update(mut self, event: Event):
        if self.editor:
            if event.message == JOBS:
                self.analysed()
                self.feed.poll(self.editor.value())
                return
            if self.editor.value().update(event):
                self.feed.poll(self.editor.value())
                if self.editor.value().closed and not self.warehouse:
                    self.editor = None
                return
        if event.message == EDIT and self.player:
            self.open_editor()
            return
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
        if self.editor and self.editor.value().draws(canvas):
            self.editor.value().draw(canvas, s, self.pal, self.font)
            return
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
        if self.editor:
            return self.editor.value().view(self.pal).padding(16, 20)
        var title = VStack(Text("Inspection flight", style=TITLE), Text(self.file + " · telemetry at 10 Hz, in step with the picture", style=CAPTION), spacing=2).align(START)
        var header = HStack(title^, Spacer(), Button("Edit", EDIT, PROMINENT, icon="video").tag("edit").tooltip("Open the editor: a filmstrip timeline with the telemetry and the defects found"),
                            spacing=12).align(CENTER).fill()
        if self.width < NARROW:
            var picture = self.player.value().view(self.width - 32)
            return VStack(header^, picture^, self.telemetry_card().height(210), self.readout(), spacing=SPACE_M).padding(16).grow().fill()
        var wide = self.width - 2 * PAD - SIDE - GAP  # the picture's width: what the side column leaves
        var picture = self.player.value().view(wide)
        var side = VStack(self.telemetry_card().grow(), self.readout(), spacing=GAP).width(SIDE).height(self.player.value().height_for(wide) + 68)
        return VStack(header^, HStack(picture^, side^, spacing=GAP).align(START).fill(), spacing=SPACE_L).padding(PAD).grow().fill().justify(CENTER)
