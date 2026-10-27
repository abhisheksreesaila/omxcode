# The model page's Benchmark tab (blade-bench.js): bars for decode tokens/s (higher is better) and time to first token
# (lower is better) across the models of the latest run, this model outlined; the workload; Run again; the history.
# Data: GET /admin/bench every 5 s (1 s while a run goes), GET /admin/bench/history?limit=10 when the latest run changes.

from mojoui.view import View, Text, Button, VStack, HStack, Spacer, PLAIN, SUBTLE, CENTER, START
from mojoui.json import Json
from mojoui.sparkline import BarView, bar_fractions, bar_order
from mojoui.panel import Card, CardHead, CardBody, CardFoot, ColumnRow, TabBody
from mojoui.header import SubHeader
from mojoui.meter import ChartRow, ShareBar
from mojoui.words import MonoLine, QuietText, Muted, MonoParagraph
from mojoui.buttons import SmallButton, PrimaryButton, FILL
from mojoui.feedback import Note, NoteAction
from data import BenchRun, BenchResult, read_run
from msgs import BENCH_RUN, BENCH_ALL, HIST, BAR
from mojoui.numformat import en_number, utc_date_time


struct Bench(Copyable, Movable):
    var loaded: Bool
    var running: Bool
    var has_latest: Bool
    var latest: BenchRun
    var history: List[BenchRun]
    var history_for: Int  # the latest run's id the history was read for (-2: never)
    var failed: String

    def __init__(out self):
        self.loaded = False
        self.running = False
        self.has_latest = False
        self.latest = BenchRun(0, 0, "", 0, 0, 0, 0, List[BenchResult]())
        self.history = List[BenchRun]()
        self.history_for = -2
        self.failed = ""

    def read(mut self, text: String) raises -> Bool:
        """/admin/bench; True when the history should be read again (first time, or a new latest run)."""
        var j = Json.parse(text)
        self.loaded = True
        self.failed = ""
        self.running = j.flag(j.get(0, "running"))
        var latest = j.get(0, "latest")
        self.has_latest = j.kind(latest) == 5
        var id = -1
        if self.has_latest:
            self.latest = read_run(j, latest)
            id = self.latest.id
        var again = self.history_for != id
        self.history_for = id
        return again

    def read_history(mut self, text: String) raises:
        var j = Json.parse(text)
        var out = List[BenchRun]()
        for k in range(j.size(0)):
            out.append(read_run(j, j.at(0, k)))
        self.history = out^


def workload(run: BenchRun) -> String:
    """workloadLine: what was sent, what came back, how often, when."""
    var out_tokens = String("up to ") + en_number(Float64(run.max_tokens)) + " tokens out"
    for r in run.results:
        if r.status == "done" and r.completion_tokens > 0:
            out_tokens = en_number(Float64(r.completion_tokens)) + " tokens out"
            break
    return (en_number(Float64(run.prompt_tokens)) + " prompt tokens · " + out_tokens + " · batch 1 · " + String(run.runs) + " run" + ("" if run.runs == 1 else "s")
            + " each · " + utc_date_time(run.started_at))


def bars(run: BenchRun, decode: Bool, me: String, first_bar: Int, mut fractions: List[Float64], mut mine: List[Bool], phone: Bool = False) -> List[View]:
    """barRows: only finished models with a number get a bar; length = value / largest; sorted best first. Each bar's
    fraction and whether it's this model go on `fractions` and `mine` (draw() paints them)."""
    var names = List[String]()
    var values = List[Float64]()
    for r in run.results:
        var v = r.decode_tps if decode else r.ttft
        if r.status == "done" and v > 0:
            names.append(r.model)
            values.append(v)
    var order = bar_order(values, names, not decode)
    var fr = bar_fractions(values)
    var rows: List[View] = []
    for k in range(len(order)):
        var i = order[k]
        fractions.append(fr[i])
        mine.append(names[i] == me)
        var value = (en_number(values[i], 1) + " tok/s") if decode else (en_number(values[i]) + " ms")
        var bar = HStack(ShareBar(Int(fr[i] * 100 + 0.5), mine=names[i] == me), spacing=0).align(CENTER).grow().tag("bar")  # (tag bar: M5 finds it)
        rows.append(ChartRow(k % 5 + 1, names[i], bar^, value, strong=names[i] == me, figure_strong=k == 0, compact=phone))
    return rows^


def bench_bars(b: Bench, model: String) -> Tuple[List[Float64], List[Bool]]:
    """The bars bench_view shows, in its order (decode speed, then first token): their fractions, and which is this model."""
    var fr = List[Float64]()
    var mine = List[Bool]()
    if b.has_latest:
        _ = bars(b.latest, True, model, 0, fr, mine)
        _ = bars(b.latest, False, model, len(fr), fr, mine)
    return (fr^, mine^)


def bench_view(b: Bench, model: String, phone: Bool) -> View:
    var fr = List[Float64]()
    var mine = List[Bool]()
    var items: List[View] = []
    var sub = model + " · " + ("latest run · " + utc_date_time(b.latest.started_at) if b.has_latest else String("no runs yet"))
    var tools: List[View] = []
    if b.has_latest or b.running:
        tools.append(SmallButton("Running…" if b.running else "Run again", BENCH_RUN, "rotate-cw", FILL))
    var head = SubHeader(sub, tools^, compact=phone)
    if not b.loaded:
        items.append(QuietText("Loading…"))
    elif not b.has_latest:
        items.append(Card([CardHead("No benchmark has run yet"),
                           CardBody([QuietText("A run loads the model if it is not running, sends one warm-up request that is not counted, then 5 timed ones."),
                                     PrimaryButton("Run benchmark", BENCH_RUN, "gauge")]), CardFoot("mxc bench " + model)]))
    else:
        var run = b.latest.copy()
        var decode = bars(run, True, model, 0, fr, mine, phone)
        var nd = len(decode)
        var ttft = bars(run, False, model, nd, fr, mine, phone)
        if nd > 0:
            items.append(Card([CardHead("Decode speed · tokens/s", "higher is better"), CardBody(decode^), CardFoot(String(run.runs) + " timed runs per model, after one warm-up", note=True)]))
        if len(ttft) > 0:
            items.append(Card([CardHead("Time to first token · p50", "lower is better"), CardBody(ttft^), CardFoot("the median of " + String(run.runs) + " timed runs", note=True)]))
        if nd == 1:
            items.append(Note([Text("Only this model has a result. To compare it with the others, run all of them."), NoteAction("Run all models", BENCH_ALL)]))
        items.append(Card([CardHead("This run"), CardBody([MonoParagraph(workload(run))]), CardFoot("mxc bench " + model)]))
        if len(b.history) > 0:
            var rows: List[View] = []
            for k in range(len(b.history)):
                ref h = b.history[k]
                var best = String("no result")
                for r in h.results:
                    if r.status == "done" and r.decode_tps > 0:
                        best = r.model + " · " + en_number(r.decode_tps, 1) + " tok/s"
                        break
                var cols: List[View] = [Muted(utc_date_time(h.started_at)), Text(String(h.models) + " model" + ("" if h.models == 1 else "s"))]
                rows.append(ColumnRow(cols^, Muted(best, mono=True), on=h.id == run.id, compact=phone))  # (a phone leaves out who ran: .bn-hwho)
            items.append(Card([CardHead("History", String(len(b.history)) + " run" + ("" if len(b.history) == 1 else "s")), VStack(rows^, spacing=0).fill(),
                               CardFoot("pick a run to chart it; newest first", note=True)]))
    return TabBody(head^, items^, compact=phone)
