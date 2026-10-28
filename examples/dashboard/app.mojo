# The data dashboard (goal 38, build D; showcase-data/SPEC.md): 100 million orders, a date range, a minimum amount and a
# region; every change recomputes the KPIs, the top-20 products and the newest 50 rows from all of them, on the GPU.
#
# The data is read once by MX frame and put on the GPU once (dashdata.mojo); each change runs as a job off the UI thread
# (the window never waits), polled once a display frame while one runs. The screen is mojoui components only: date
# pickers, a slider, a dropdown, KPI cards, a ChartView on a Canvas and a Table, in omxqua.
#
# Scripted (for measuring): dashboard --scripted --rows 10M|100M [--steps S] [--out DIR] (or DASH_SCRIPTED=1, DASH_ROWS,
# DASH_STEPS, DASH_OUT; --data FILE for another file): opens data/orders-<rows>.parquet, shows the opening state, then
# applies steps 1 … S of showcase-data/steps.json one after another, each when the last one's numbers are on screen;
# writes DIR/answers.json (SPEC's format) and DIR/timings.json (per step: input_to_pixels_ms = the change → the frame
# that draws its numbers; compute_ms = the job; query_ms = MX frame's GPU group-by; rows_ms = the table's rows on the
# GPU), then exits. It prints "dashboard: first dashboard" when the opening state is first drawn.
#
# Driven from outside (a shared harness that watches the screen): dashboard --scripted-external --rows 10M|100M [--out
# DIR] (or DASH_EXTERNAL=1): opens the file, shows the opening state (step 0), then waits; each line "step N" on stdin
# applies steps.json's state N (read on the main loop as it arrives: App.input_lines), "quit" or the end of stdin
# writes DIR/answers.json and DIR/timings.json for the steps shown, in the order asked (once the last one asked for is
# on screen), and exits. Stdout speaks the harness's driver contract (docs/goals/38/README.md): `ready <json>` once
# step 0 is drawn (the load figures), `shown N <ms> <json>` as each later step is drawn (ms: change → that frame; json:
# gpu_ms, compute_ms), `error <text>`, `bye`.

from std.sys import argv, exit
from std.os import getenv
from std.math import log, exp

from mojoui import (
    App, Event, View, Surface, VStack, HStack, Text, Slider, Canvas, Spacer, Card, Dropdown, Scroll,
    HEADLINE, TITLE, CAPTION, CENTER, START, NO_MSG, TONE_GOOD,
)
from mojoui.view import SPACE_S, SPACE_M
from mojoui.shell import Shell, AppBar
from mojoui.chartview import ChartView
from mojoui.kpi import KpiView
from mojoui.table import Table
from mojoui.fields import DateField, DatePopover
from mojoui.json import Json, json_string
from mojoui.text import Font
from mojoui.clock import now_ns
from mojoui.theme import Theme, Palette
from themes.omxqua import omxqua, omxqua_palette
from mxframe import Job, JOB_RUNNING, start_job
from dashdata import (Orders, Answer, Filters, LoadJob, StepJob, ALL, TOP, money, day_number, day_text, ms_since)

comptime FRAME = 1
comptime FROM = 2
comptime TO = 3
comptime AMOUNT = 4
comptime REGION = 5
comptime OPEN_FROM = 6
comptime OPEN_TO = 7
comptime CLOSE_DATE = 8
comptime STEP_LINE = 20  # --scripted-external: a line from stdin ("step N", "quit"; number -1: stdin closed)
comptime CHART = 1  # the bar chart's canvas

comptime W = 1280
comptime H = 800
comptime MAX_AMOUNT = 5000.0
comptime COLUMNS: List[String] = ["Day", "Id", "Region", "Product", "Amount", "Cost", "Paid"]


# ---------- flags ----------

def flag(name: String, env: String, fallback: String) -> String:
    var args = argv()
    for i in range(len(args)):
        if String(args[i]) == name:
            return String(args[i + 1]) if i + 1 < len(args) and not String(args[i + 1]).startswith("--") else "1"
    var v = getenv(env)
    return v if v != "" else fallback


def number(s: String, fallback: Int) -> Int:
    try:
        return Int(s)
    except:
        return fallback


def fixed(x: Float64, places: Int) -> String:
    var scale = 10 ** places
    var v = Int(abs(x) * Float64(scale) + 0.5)
    var frac = String(v % scale)
    while frac.byte_length() < places:
        frac = "0" + frac
    return ("-" if x < 0 and v > 0 else "") + String(v // scale) + ("." + frac if places > 0 else "")


def grouped(n: Int) -> String:
    var s = String(abs(n))
    var out = String("")
    var k = s.byte_length()
    for i in range(k):
        if i > 0 and (k - i) % 3 == 0:
            out += ","
        out += s[byte=i]
    return ("-" if n < 0 else "") + out


def dollars(cents: Int) -> String:
    """$1,234,567 (whole dollars, rounded)."""
    return "$" + grouped((cents + 50) // 100)


# ---------- the slider: 0–100 on a log scale, 1 … 5,000 ----------

def slider_amount(v: Int) -> Float64:
    return Float64(Int(exp(log(MAX_AMOUNT) * Float64(v) / 100.0) + 0.5))


def amount_slider(amount: Float64) -> Int:
    return min(max(Int(100.0 * log(max(amount, 1.0)) / log(MAX_AMOUNT) + 0.5), 0), 100)


# ---------- the steps ----------

def read_steps(path: String, mut states: List[Filters], mut changes: List[String]) raises:
    """The opening state and each step's full state, from steps.json."""
    var text: String
    with open(path, "r") as f:
        text = f.read()
    var j = Json.parse(text)
    var all = List[Int]()
    all.append(j.get(0, "opening"))
    var list = j.get(0, "steps")
    for i in range(j.size(list)):
        all.append(j.at(list, i))
    for node in all:
        states.append(Filters(day_number(j.text(j.get(node, "from"))), day_number(j.text(j.get(node, "to"))),
                                   j.real(j.get(node, "min_amount")), j.text(j.get(node, "region"))))
        changes.append(j.text(j.get(node, "change"), "opening"))


# ---------- the app ----------

struct Main(App):
    var pal: Palette
    var glyphs: Font  # (the framework's own type, for the chart's labels)
    var path: String
    var rows_name: String
    var orders: Optional[Orders]
    var loading: Optional[Job[Orders]]
    var running: Optional[Job[Answer]]
    var running_step: Int  # the step the running job answers
    var pending: Bool  # the controls moved while a job ran: run again when it lands
    var problem: String
    var filters: Filters
    var picking: Int  # the date whose calendar is open: OPEN_FROM, OPEN_TO or 0
    var answer: Optional[Answer]
    var answer_step: Int
    var version: Int  # the chart's canvas: bumps when an answer lands
    var drawn: Int  # the version last drawn
    var started_ns: Int
    # scripted
    var scripted: Bool
    var external: Bool  # --scripted-external: steps come from stdin
    var want_record: Bool  # (scripted or external) the next answer drawn for the current step is recorded
    var quitting: Bool  # (external) "quit" came while a step was on its way: finish once it's drawn
    var out: String
    var states: List[Filters]  # the opening state, then each step's full state
    var changes: List[String]
    var steps: Int  # S: steps 1 … S are applied
    var step: Int  # the step on screen (or being computed)
    var change_ns: Int  # when the controls last changed
    var answers: List[String]  # answers.json entries, per step
    var timings: List[String]
    var first_ms: Float64

    def __init__(out self):
        self.started_ns = now_ns()
        self.pal = omxqua_palette(False)
        self.glyphs = Font()
        self.scripted = flag("--scripted", "DASH_SCRIPTED", "") != ""
        self.external = flag("--scripted-external", "DASH_EXTERNAL", "") != ""
        if self.external:
            self.scripted = False
        self.want_record = True
        self.quitting = False
        self.rows_name = flag("--rows", "DASH_ROWS", "100M")
        self.path = flag("--data", "DASH_DATA", "data/orders-" + self.rows_name + ".parquet")
        self.out = flag("--out", "DASH_OUT", ".")
        self.states = List[Filters]()
        self.changes = List[String]()
        self.problem = ""
        try:
            read_steps(flag("--steps-file", "DASH_STEPS_FILE", "showcase-data/steps.json"), self.states, self.changes)
        except e:
            self.problem = "couldn't read the steps: " + String(e)
        if len(self.states) == 0:
            self.states.append(Filters(day_number_or("2024-01-01"), day_number_or("2025-12-31"), 1.0, ALL))
            self.changes.append("opening")
        self.steps = min(number(flag("--steps", "DASH_STEPS", String(len(self.states) - 1)), len(self.states) - 1), len(self.states) - 1)
        self.filters = self.states[0].copy()
        self.picking = 0
        self.orders = None
        self.running = None
        self.running_step = 0
        self.pending = False
        self.answer = None
        self.answer_step = -1
        self.version = 0
        self.drawn = 0
        self.step = 0
        self.change_ns = now_ns()
        self.answers = List[String]()
        self.timings = List[String]()
        self.first_ms = 0
        self.loading = start_job(LoadJob(self.path))

    def title(self) -> String:
        return "Orders dashboard"

    def window_size(self) -> Tuple[Int, Int]:
        return (W, H)

    def theme(self) -> Theme:
        return omxqua(False)

    def input_lines(self) -> Int:
        return STEP_LINE if self.external else 0

    # ---------- work ----------

    def busy(self) -> Bool:
        return Bool(self.loading) or Bool(self.running) or self.scripted  # (scripted: each frame looks for the next step)

    def run(mut self):
        """Starts the job for the controls as they are now (one at a time: a change during a job waits for it)."""
        if not self.orders:
            return
        if self.running:
            self.pending = True
            return
        self.pending = False
        self.running_step = self.step
        self.running = start_job(StepJob(self.orders.value(), self.filters))

    def changed(mut self):
        self.change_ns = now_ns()
        self.want_record = True
        self.run()

    def poll(mut self):
        if self.loading and self.loading.value().poll() != JOB_RUNNING:
            var job = self.loading.take()
            try:
                self.orders = job.result()
                self.change_ns = now_ns()
                self.run()
            except e:
                self.problem = "couldn't open " + self.path + ": " + String(e)
                print("dashboard: " + self.problem, flush=True)
                if self.external:
                    print("error " + self.problem, flush=True)
                if self.scripted:
                    exit(1)
        if self.running and self.running.value().poll() != JOB_RUNNING:
            var job = self.running.take()
            try:
                self.answer = job.result()
                self.answer_step = self.running_step
                self.version += 1
            except e:
                self.problem = String(e)
                print("dashboard: step " + String(self.running_step) + " failed: " + self.problem, flush=True)
                if self.external:
                    print("error step " + String(self.running_step) + ": " + self.problem, flush=True)
                if self.scripted:
                    exit(1)
            if self.pending:
                self.run()
        # scripted: the next step once this one's numbers are drawn
        if self.scripted and not self.running and self.answer and self.drawn == self.version and self.answer_step == self.step \
                and len(self.answers) == self.step + 1 and self.step < self.steps:
            self.step += 1
            self.filters = self.states[self.step].copy()
            self.changed()

    def update(mut self, event: Event):
        if event.message == FRAME:
            self.poll()
            return
        if event.message == STEP_LINE:
            self.external_step(event)
            return
        if self.scripted or self.external:
            return
        if event.message == OPEN_FROM or event.message == OPEN_TO:
            self.picking = 0 if self.picking == event.message else event.message
        elif event.message == CLOSE_DATE:
            self.picking = 0
        elif event.message == FROM or event.message == TO:
            self.picking = 0
            try:
                var d = day_number(event.text)
                if event.message == FROM:
                    self.filters.from_day = d
                else:
                    self.filters.to_day = d
                self.changed()
            except:
                pass
        elif event.message == AMOUNT:
            var m = slider_amount(event.number)
            if m != self.filters.min_amount:
                self.filters.min_amount = m
                self.changed()
        elif event.message == REGION:
            var names = self.region_names()
            var r = String(ALL) if event.number <= 0 or event.number > len(names) else names[event.number - 1]
            if r != self.filters.region:
                self.filters.region = r
                self.changed()

    def external_step(mut self, event: Event):
        """--scripted-external: "step N" shows steps.json's state N; "quit" (or stdin closing) writes the results."""
        var line = event.text.strip()
        if event.number == -1 or line == "quit":
            if self.want_record and self.orders and self.problem == "":
                self.quitting = True  # (the step asked for last is still on its way)
            else:
                self.finish()
            return
        if line.startswith("step "):
            var n = number(String(line[byte=5:]), -1)
            if n >= 0 and n < len(self.states):
                self.step = n
                self.filters = self.states[n].copy()
                self.changed()
                return
        print("error not a step: '" + String(line) + "' (send 'step N', N from 0 to " + String(len(self.states) - 1) + ", or 'quit')", flush=True)

    def region_names(self) -> List[String]:
        """The regions, A to Z."""
        var names = self.orders.value().regions.copy() if self.orders else List[String]()
        sort(names)
        return names^

    # ---------- drawing ----------

    def chart(self) -> ChartView:
        var labels = List[String]()
        var values = List[Float64]()
        if self.answer:
            ref a = self.answer.value()
            for i in range(len(a.top_names)):
                labels.append(a.top_names[i])
                values.append(Float64(a.top_cents[i]))
        return ChartView("Sales by product · top " + String(TOP), labels^, values^, "sales", True)

    def draw(mut self, canvas: Int, mut s: Surface):
        if canvas != CHART:
            return
        var cv = self.chart()
        cv.draw(s, self.glyphs, self.pal)
        if self.drawn == self.version:
            return
        self.drawn = self.version
        if not self.answer:
            return
        var shown_ms = ms_since(self.change_ns)
        if self.answer_step == 0 and self.first_ms == 0:
            self.first_ms = ms_since(self.started_ns)
            print("dashboard: first dashboard " + fixed(self.first_ms, 1) + " ms", flush=True)
        if (self.scripted or self.external) and self.want_record and self.answer_step == self.step:
            self.want_record = False
            self.record(shown_ms)
            if (self.scripted and self.step == self.steps) or self.quitting:
                self.finish()

    def record(mut self, shown_ms: Float64):
        ref a = self.answer.value()
        var top = String("[")
        for i in range(len(a.top_names)):
            top += ("," if i > 0 else "") + "[" + json_string(a.top_names[i]) + "," + String(Float64(a.top_cents[i]) / 100.0) + "]"
        var ids = String("[")
        for i in range(len(a.ids)):
            ids += ("," if i > 0 else "") + String(a.ids[i])
        self.answers.append('{"step": ' + String(self.step) + ', "rows": ' + String(a.rows) + ', "sum_amount": '
                            + String(a.sum_amount()) + ', "avg_margin": ' + (String(a.avg_profit()) if a.rows > 0 else "null")
                            + ', "top": ' + top + '], "ids": ' + ids + "]}")
        if self.external:  # (the harness's driver contract, docs/goals/38/README.md: the app's own figures, nothing else)
            if len(self.answers) == 1:
                ref o = self.orders.value()
                print('ready {"data_load_ms": ' + fixed(o.read_ms + o.cents_ms + o.sort_ms + o.upload_ms, 1) + ', "read_ms": '
                      + fixed(o.read_ms, 1) + ', "cents_ms": ' + fixed(o.cents_ms, 1) + ', "sort_ms": ' + fixed(o.sort_ms, 1)
                      + ', "upload_ms": ' + fixed(o.upload_ms, 1) + ', "first_dashboard_ms": ' + fixed(self.first_ms, 1) + "}", flush=True)
            else:
                print("shown " + String(self.step) + " " + fixed(shown_ms, 3) + ' {"gpu_ms": ' + fixed(a.query_ms + a.rows_ms, 3)
                      + ', "compute_ms": ' + fixed(a.compute_ms, 3) + "}", flush=True)
        self.timings.append('{"step": ' + String(self.step) + ', "change": ' + json_string(self.changes[self.step])
                            + ', "rows": ' + String(a.rows) + ', "input_to_pixels_ms": ' + fixed(shown_ms, 3)
                            + ', "compute_ms": ' + fixed(a.compute_ms, 3) + ', "query_ms": ' + fixed(a.query_ms, 3)
                            + ', "rows_ms": ' + fixed(a.rows_ms, 3) + "}")

    def finish(mut self):
        if not self.orders:
            print("dashboard: the data never loaded: " + self.problem, flush=True)
            exit(1)
        ref o = self.orders.value()
        try:
            with open(self.out + "/answers.json", "w") as f:
                f.write('{"file": ' + json_string(self.path) + ', "steps": [\n')
                for i in range(len(self.answers)):
                    f.write(self.answers[i] + (",\n" if i + 1 < len(self.answers) else "\n"))
                f.write("]}\n")
            with open(self.out + "/timings.json", "w") as f:
                f.write('{"build": "D omxcode", "rows": ' + String(o.rows()) + ', "device": ' + json_string(o.device)
                        + ', "read_ms": ' + fixed(o.read_ms, 1) + ', "cents_ms": ' + fixed(o.cents_ms, 1) + ', "sort_ms": ' + fixed(o.sort_ms, 1)
                        + ', "upload_ms": ' + fixed(o.upload_ms, 1) + ', "first_dashboard_ms": ' + fixed(self.first_ms, 1)
                        + ', "gpu_table_bytes": ' + String(o.gpu_bytes()) + ',\n "steps": [\n')
                for i in range(len(self.timings)):
                    f.write(self.timings[i] + (",\n" if i + 1 < len(self.timings) else "\n"))
                f.write("]}\n")
        except e:
            print("dashboard: couldn't write the results: " + String(e), flush=True)
            exit(1)
        print("dashboard: wrote " + self.out + "/answers.json and timings.json", flush=True)
        if self.external:
            print("bye", flush=True)
        exit(0)

    # ---------- the screen ----------

    def kpis(self) -> View:
        var total = self.orders.value().rows() if self.orders else 0
        var rows = String("—")
        var sales = String("—")
        var profit = String("—")
        var share = String("")
        if self.answer:
            ref a = self.answer.value()
            rows = grouped(a.rows)
            sales = dollars(a.sum_cents)
            profit = fixed(100.0 * a.avg_profit(), 2) + " %" if a.rows > 0 else String("none")
            share = fixed(100.0 * Float64(a.rows) / Float64(max(total, 1)), 2) + " % of rows"
        return HStack(
            KpiView("Rows matched", rows, share, [], True, 0).view(0, 0, fact="of " + grouped(total)).grow(),
            KpiView("Sum of amount", sales, "all matching orders", [], False, 0).view(0, 0, fact="exact, in cents").grow(),
            KpiView("Average margin", profit, "(amount − cost) / amount", [], False, TONE_GOOD).view(0, 0, fact="mean over rows").grow(),
            spacing=SPACE_M,
        ).fill()

    def controls(self) -> View:
        var regions: List[String] = ["All regions"]
        var at = 0
        var names = self.region_names()
        for i in range(len(names)):
            regions.append(names[i])
            if names[i] == self.filters.region:
                at = i + 1
        return HStack(
            Text("From", style=CAPTION), DateField(day_text(self.filters.from_day), OPEN_FROM, "from-date"),
            Text("To", style=CAPTION), DateField(day_text(self.filters.to_day), OPEN_TO, "to-date"),
            Text("Min amount", style=CAPTION), Slider(amount_slider(self.filters.min_amount), AMOUNT).grow(),
            Text("$" + grouped(Int(self.filters.min_amount)), style=HEADLINE),
            Text("Region", style=CAPTION), Dropdown(regions^, at, REGION),
            spacing=SPACE_S,
        ).align(CENTER).fill()

    def status(self) -> String:
        if self.problem != "":
            return self.problem
        if self.loading:
            return "Loading " + self.rows_name + " rows onto the GPU…"
        if not self.answer:
            return "Computing…"
        ref a = self.answer.value()
        var s = self.orders.value().device + " · " + fixed(a.compute_ms, 1) + " ms (group-by " + fixed(a.query_ms, 1) + ", rows " + fixed(a.rows_ms, 1) + ")"
        return s + (" · computing…" if self.running else "")

    def table(self) -> View:
        var cells = List[View]()
        if self.answer:
            for c in self.answer.value().cells:
                cells.append(Text(c))
        return Table(materialize[COLUMNS](), cells^, align="LRLLRRL", dense=True)

    def view(self) -> View:
        var total = self.orders.value().rows() if self.orders else 0
        var bar: List[View] = [
            Text("Orders", style=TITLE),
            Text(grouped(total) + " rows · newest 50 below" if total > 0 else "", style=CAPTION),
            Spacer(),
            Text(self.status(), style=CAPTION).tag("status"),
        ]
        var chart = Card(Canvas(CHART, self.version, on_frame=FRAME if self.busy() else NO_MSG).grow().fill(), spacing=0).grow().fill()
        var rows = Card(Scroll(self.table(), height=0).grow(), spacing=0).grow().fill()
        var page = VStack(self.controls(), self.kpis(), HStack(chart^, rows^, spacing=SPACE_M).fill().grow(), spacing=SPACE_M).grow().fill()
        var screen: List[View] = [Shell(AppBar(bar^), page^)]
        if self.picking == OPEN_FROM:
            screen.append(DatePopover("from-date", "From", day_text(self.filters.from_day), FROM, CLOSE_DATE))
        elif self.picking == OPEN_TO:
            screen.append(DatePopover("to-date", "To", day_text(self.filters.to_day), TO, CLOSE_DATE))
        return VStack(screen^, spacing=0).grow().fill()


def day_number_or(iso: String) -> Int:
    try:
        return day_number(iso)
    except:
        return 0
