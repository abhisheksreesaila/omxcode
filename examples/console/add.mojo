# Add a model (blade-add.js, F-026): one search over the MAX catalog and Hugging Face, each result marked fits / tight
# fit / too big / needs porting for this machine; picking one runs the setup stages (check hardware, fetch, compile
# graph, serve on localhost, smoke test) with the ring timeline, elapsed times and a live log, and ends on a Ready card
# with a curl to copy. A model that won't fit gets a warning with smaller ones to pick instead; an architecture MAX
# can't run yet offers "Port it" (/admin/ports, polled every 1.5 s). The search waits 250 ms after the last key; a pull
# is polled every 0.7 s; the stages' clock ticks every 0.5 s. This file is the state and its rules (the original's pure
# helpers, ported) and the screen; addflow.mojo is what each message and reply does.

from mojoui.shared import floored
from mojoui.view import View, Text, VStack, HStack, Spacer, Scroll, Divider, START, CENTER, END
from mojoui.json import Json, J_NULL, J_NUMBER, J_STRING, J_ARRAY, J_OBJECT
from mojoui.timeline import Timeline, Stage, STAGE_PENDING, STAGE_RUNNING, STAGE_DONE, STAGE_FAILED, STAGE_CANCELLED, elapsed_text, stage_elapsed
from mojoui.logview import LogPane, LogLine, LOG_PLAIN, LOG_ERROR, LOG_OK, LOG_WARN
from mojoui.codeblock import CodeBlock
from mojoui.chip import Badge, BADGE_OK, BADGE_WARN, BADGE_PLAIN
from mojoui.skeleton import Skeleton
from mojoui.fields import OutlinedField, FieldWithHelp, FilterChips
from mojoui.results import ResultRow, SuggestionTile, SuggestionRow
from mojoui.meter import Meter
from mojoui.feedback import EmptyState
from mojoui.buttons import SmallButton, BackButton, ButtonRow, TONAL, FILL, TEXT
from mojoui.copy import CopyRow
from mojoui.marks import StatusMark, GOOD, WARN, BAD, INFO, QUIET
from mojoui.header import PageHeader, IconSquare
from mojoui.panel import Card, CardHead, CardFoot, CardBody, CardColumn, Fact, FactText, FactList
from mojoui.words import QuietText, WarnLine
from mojoui.lists import PageColumn, MainAside
from mojoui.skeleton import SkeletonList
from mojoui.shell import PageCard

from api import chat_curl
from msgs import *
from mojoui.numformat import en_number

comptime DEFAULT_SUB = "Search the MAX catalog and Hugging Face · every result is checked against this machine's memory"
comptime ORDER: List[String] = ["check", "fetch", "compile", "serve", "smoke"]
comptime LABELS: List[String] = ["Check hardware", "Fetch the model", "Compile graph", "Serve on localhost", "Smoke test"]
comptime FILTER_TITLES: List[String] = ["All", "Fits", "Needs porting"]
comptime PORT_NOTE = ("“Port it” runs Claude Code with Modular’s import-model skill, unattended and in a sandbox: it reads the config, writes the model "
                      + "as a MAX graph, checks it against the reference and fixes what fails. It may take a while, often several minutes and sometimes "
                      + "much longer, and it uses your Claude Code session. You will see every stage and the full log, and you can cancel.")


# ---------- pure: formatting (blade-add.js) ----------

def trim1(n: Float64) -> String:
    """String(Number(n.toFixed(1))): 24.0 → "24", 14.94 → "14.9"."""
    return en_number(n, 1).replace(",", "")


def size_text(gb: Float64) -> String:
    return "" if gb < 0 else trim1(gb) + " GB"


def params_text(n: Float64) -> String:
    if n <= 0:
        return ""
    if n >= 1e9:
        return trim1(n / 1e9) + "B"
    return String(Int(floored(n / 1e6 + 0.5))) + "M"


def bytes_text(n: Float64) -> String:
    if n < 0:
        return ""
    if n >= 1e9:
        return trim1(n / 1e9) + " GB"
    if n >= 1e6:
        return String(Int(floored(n / 1e6 + 0.5))) + " MB"
    if n >= 1e3:
        return String(Int(floored(n / 1e3 + 0.5))) + " KB"
    return String(Int(n)) + " B"


def eta_text(sec: Float64) -> String:
    if sec < 60:
        return String(Int(floored(sec + 0.5))) + "s"
    var r = Int(floored(sec - 60 * floored(sec / 60) + 0.5))
    return String(Int(floored(sec / 60))) + "m " + ("0" if r < 10 else "") + String(r) + "s"


def arch_short(a: String) -> String:
    for suffix in ["ForCausalLM", "ForConditionalGeneration", "LMHeadModel"]:
        if a.endswith(suffix):
            return String(a[byte = : a.byte_length() - suffix.byte_length()])
    return a


def twin(kind: String, mref: String) -> String:
    """The mxc command that does the same thing as an action here."""
    if kind == "pull":
        return "mxc pull " + mref
    if kind == "serve":
        return "mxc serve " + mref
    if kind == "port":
        return "mxc port " + mref + " --auto"
    if kind == "guided":
        return "mxc port " + mref
    if kind == "search":
        return "mxc search " + mref
    if kind == "ps":
        return "mxc ps"
    return ""


def joined(parts: List[String]) -> String:
    """parts.filter(Boolean).join(" · ")"""
    var out = String("")
    for p in parts:
        if p != "":
            out += (" · " if out != "" else "") + p
    return out


def last_part(mref: String) -> String:
    var parts = mref.split("/")
    return String(parts[len(parts) - 1])


# ---------- the replies ----------

@fieldwise_init
struct Sugg(Copyable, Movable):
    """A smaller model suggested instead of one too big."""
    var id: String
    var repo: String
    var arch: String
    var params: Float64
    var size_gb: Float64
    var est_gb: Float64


@fieldwise_init
struct Pick(Copyable, Movable):
    """A search result."""
    var id: String
    var repo: String
    var source: String  # max, hf
    var arch: String
    var params: Float64  # -1 unknown
    var size_gb: Float64
    var est_gb: Float64
    var fit: String  # ok, tight, no, port; "" unknown
    var suggestions: List[Sugg]


def real_of(j: Json, node: Int) -> Float64:
    return j.real(node) if j.kind(node) == J_NUMBER else -1.0


def read_pick(j: Json, r: Int) -> Pick:
    var sug = List[Sugg]()
    var ss = j.get(r, "suggestions")
    for k in range(j.size(ss)):
        var x = j.at(ss, k)
        sug.append(Sugg(j.text(j.get(x, "id")), j.text(j.get(x, "repo_id")), j.text(j.get(x, "architecture")), real_of(j, j.get(x, "params")),
                        real_of(j, j.get(x, "size_gb")), real_of(j, j.get(x, "est_vram_gb"))))
    var repo = j.text(j.get(r, "repo_id"))
    return Pick(j.text(j.get(r, "id")), repo, j.text(j.get(r, "source"), "max"), j.text(j.get(r, "architecture")), real_of(j, j.get(r, "params")),
                real_of(j, j.get(r, "size_gb")), real_of(j, j.get(r, "est_vram_gb")), j.text(j.get(r, "fit")), sug^)


@fieldwise_init
struct PullStep(Copyable, Movable):
    var id: String
    var label: String
    var state: String  # done, now, next
    var detail: String


@fieldwise_init
struct PortStage(Copyable, Movable):
    var name: String
    var status: String
    var started: Float64  # epoch seconds, -1 none
    var ended: Float64
    var detail: String
    var attempt: Int


struct Job(Copyable, Movable):
    """A pull or port job as the daemon writes it (the fields the screen reads)."""
    var present: Bool
    var id: Int
    var name: String
    var status: String
    var step: String
    var message: String
    var hint: String
    var total: Float64
    var done: Float64
    var percent: Float64  # -1 none
    var speed: Float64
    var eta: Float64
    var files: Int
    var steps: List[PullStep]
    var stages: List[PortStage]
    var log_tail: List[String]
    var model: String

    def __init__(out self):
        self.present = False
        self.id = 0
        self.name = ""
        self.status = ""
        self.step = ""
        self.message = ""
        self.hint = ""
        self.total = 0
        self.done = 0
        self.percent = -1
        self.speed = 0
        self.eta = 0
        self.files = 0
        self.steps = List[PullStep]()
        self.stages = List[PortStage]()
        self.log_tail = List[String]()
        self.model = ""

    def finished(self) -> Bool:
        return self.status == "done" or self.status == "failed" or self.status == "cancelled" or self.status == "unsupported"


def read_job(j: Json, n: Int) -> Job:
    var job = Job()
    job.present = j.kind(n) == J_OBJECT
    job.id = j.number(j.get(n, "id"))
    job.name = j.text(j.get(n, "name"))
    job.status = j.text(j.get(n, "status"))
    job.step = j.text(j.get(n, "step"))
    job.message = j.text(j.get(n, "message"))
    job.hint = j.text(j.get(n, "hint"))
    job.total = max(real_of(j, j.get(n, "total_bytes")), 0.0)
    job.done = max(real_of(j, j.get(n, "done_bytes")), 0.0)
    job.percent = real_of(j, j.get(n, "percent"))
    job.speed = max(real_of(j, j.get(n, "speed")), 0.0)
    job.eta = max(real_of(j, j.get(n, "eta_seconds")), 0.0)
    job.files = j.size(j.get(n, "files"))
    var steps = j.get(n, "steps")
    for k in range(j.size(steps)):
        var s = j.at(steps, k)
        job.steps.append(PullStep(j.text(j.get(s, "id")), j.text(j.get(s, "label")), j.text(j.get(s, "state")), j.text(j.get(s, "detail"))))
    var stages = j.get(n, "stages")
    for k in range(j.size(stages)):
        var s = j.at(stages, k)
        job.stages.append(PortStage(j.text(j.get(s, "name")), j.text(j.get(s, "status"), "pending"), real_of(j, j.get(s, "started")),
                                    real_of(j, j.get(s, "ended")), j.text(j.get(s, "detail")), j.number(j.get(s, "attempt"))))
    var tail = j.get(n, "log_tail")
    if j.kind(tail) == J_STRING:
        for l in j.text(tail).split("\n"):
            job.log_tail.append(String(l))
    elif j.kind(tail) == J_ARRAY:
        for k in range(j.size(tail)):
            var l = j.at(tail, k)
            job.log_tail.append(j.text(l) if j.kind(l) == J_STRING else j.text(j.get(l, "line"), j.text(j.get(l, "text"), j.text(j.get(l, "message")))))
    job.model = j.text(j.get(n, "model"))
    return job^


def pull_detail(job: Job) -> String:
    """One line about a pull: bytes, speed, files and time left while downloading, the step's own note otherwise."""
    if not job.present:
        return ""
    if job.status == "failed" or job.status == "cancelled" or job.status == "unsupported":
        return joined([job.message, job.hint])
    var note = String("")
    var found = False
    for s in job.steps:
        if s.state == "now":
            note = s.detail
            found = True
            break
    if not found:
        for k in range(len(job.steps) - 1, -1, -1):
            if job.steps[k].detail != "":
                note = job.steps[k].detail
                break
    if job.status == "running" and job.step == "download" and (job.total > 0 or job.done > 0):
        var parts: List[String] = [bytes_text(job.done) + " of " + bytes_text(job.total) if job.total > 0 else bytes_text(job.done)]
        if job.speed > 0:
            parts.append(bytes_text(job.speed) + "/s")
        if job.files > 0:
            parts.append(String(job.files) + " file" + ("" if job.files == 1 else "s"))
        if job.eta > 0:
            parts.append(eta_text(job.eta) + " left")
        return joined(parts)
    if job.status == "done":
        return (bytes_text(job.total) + " on disk · files verified") if job.total > 0 else job.message
    return note if note != "" else String("starting…")


def port_label(name: String) -> String:
    var key = name.lower().replace("_", " ").replace("-", " ").strip()
    var keys: List[String] = ["workspace", "skills", "generate", "build", "parity", "parity check", "register", "serve"]
    var labels: List[String] = ["Prepare workspace", "Load Modular skills", "Generate the model", "Build the graph", "Parity check", "Parity check",
                                "Register the model", "Serve on localhost"]
    for k in range(len(keys)):
        if keys[k] == key:
            return labels[k]
    var s = String(key)
    return s[byte = :1].upper() + String(s[byte = 1:]) if s.byte_length() > 0 else s


def stage_status(s: String) -> Int:
    if s == "running":
        return STAGE_RUNNING
    if s == "done":
        return STAGE_DONE
    if s == "failed":
        return STAGE_FAILED
    if s == "cancelled":
        return STAGE_CANCELLED
    return STAGE_PENDING


# ---------- the run ----------

struct Run(Copyable, Movable):
    """A pull or port run: blade-add.js's ui.run."""
    var kind: String  # pull, port
    var source: Pick
    var mref: String
    var name: String
    var phase: String  # fetch, compile, serve, smoke, ready, failed, cancelled
    var failed_at: String
    var error: String
    var hw: String
    var fetch: Job
    var port: Job
    var smoke: String
    var endpoint: String
    var starts: List[Float64]  # ms per ORDER stage, -1 none
    var ends: List[Float64]

    def __init__(out self, kind: String, var source: Pick, mref: String, hw: String, now: Float64):
        self.kind = kind
        self.source = source^
        self.mref = mref
        self.name = mref
        self.phase = "fetch"
        self.failed_at = ""
        self.error = ""
        self.hw = hw
        self.fetch = Job()
        self.port = Job()
        self.smoke = ""
        self.endpoint = ""
        self.starts = [now, now, -1.0, -1.0, -1.0]
        self.ends = [now, -1.0, -1.0, -1.0, -1.0]

    def index(self, id: String) -> Int:
        var order = materialize[ORDER]()
        for k in range(len(order)):
            if order[k] == id:
                return k
        return -1


def base_stage(run: Run, cur: Int, i: Int, now: Float64) -> Stage:
    var status = STAGE_DONE if i < cur else (STAGE_PENDING if i > cur else (STAGE_FAILED if run.phase == "failed" else (STAGE_CANCELLED if run.phase == "cancelled" else STAGE_RUNNING)))
    var row = Stage(materialize[LABELS]()[i], status, stage_elapsed(run.starts[i], run.ends[i], status, now))
    if status == STAGE_FAILED:
        row.detail = run.error
    return row^


def setup_stages(run: Run, now: Float64) -> List[Stage]:
    """blade-add.js setupStages: the five-stage timeline (a port run swaps "fetch" for the port job's own stages)."""
    var order = materialize[ORDER]()
    var cur = len(order) if run.phase == "ready" else run.index(run.failed_at if run.phase == "failed" or run.phase == "cancelled" else run.phase)
    var name = run.name if run.name != "" else run.mref
    var rows = List[Stage]()
    var check = base_stage(run, cur, 0, now)
    check.detail = run.hw
    check.twin = twin("search", run.mref)
    rows.append(check^)
    if run.kind == "port":
        var pr = List[Stage]()
        for s in run.port.stages:
            var st = stage_status(s.status)
            var end = s.ended * 1000 if s.ended >= 0 else (now if st == STAGE_RUNNING else -1.0)
            var el = max(0.0, end - s.started * 1000) if s.started >= 0 and end >= 0 else -1.0
            pr.append(Stage(port_label(s.name) + (" · attempt " + String(s.attempt) if s.attempt > 1 else String("")), st, el, s.detail))
        if len(pr) == 0:
            var st = STAGE_FAILED if run.phase == "failed" else (STAGE_CANCELLED if run.phase == "cancelled" else (STAGE_DONE if cur > 1 else STAGE_RUNNING))
            pr.append(Stage("Start the port", st, stage_elapsed(run.starts[1], run.ends[1], STAGE_RUNNING, now), run.error))
        pr[0].twin = twin("port", run.mref)
        rows += pr^
    else:
        var f = base_stage(run, cur, 1, now)
        f.twin = twin("pull", run.mref)
        if f.status == STAGE_DONE:
            f.percent = 100
        elif f.status == STAGE_RUNNING and run.fetch.percent >= 0:
            f.percent = Int(run.fetch.percent)
        if f.status != STAGE_FAILED:
            var d = pull_detail(run.fetch)
            f.detail = d if d != "" else (String("starting…") if f.status == STAGE_RUNNING else String(""))
        if f.status == STAGE_CANCELLED:
            f.detail = "cancelled"
        rows.append(f^)
    var compile = base_stage(run, cur, 2, now)
    compile.twin = twin("serve", name)
    if compile.status == STAGE_RUNNING:
        compile.detail = "building the graph for this GPU · the first start takes a while"
    elif compile.status == STAGE_DONE:
        compile.detail = "graph compiled"
    var serve = base_stage(run, cur, 3, now)
    serve.twin = twin("ps", "")
    if serve.status == STAGE_RUNNING:
        serve.detail = "waiting for the server to answer"
    elif serve.status == STAGE_DONE:
        serve.detail = ("answering at " + run.endpoint) if run.endpoint != "" else String("answering on localhost")
    var smoke = base_stage(run, cur, 4, now)
    if smoke.status == STAGE_RUNNING:
        smoke.detail = "asking for one short reply"
    elif smoke.status == STAGE_DONE and run.smoke != "":
        smoke.detail = "“" + run.smoke + "”"
    if run.kind != "port":  # (a port job registers and serves the model itself: only the smoke test follows it)
        rows.append(compile^)
        rows.append(serve^)
    rows.append(smoke^)
    return rows^


# ---------- the screen's state ----------

comptime NOTICE_NONE = 0
comptime NOTICE_WARN = 1  # too big
comptime NOTICE_PORT = 2  # needs porting


struct Add(Copyable, Movable):
    var q: String
    var seq: Int  # the newest search's number (older answers are dropped)
    var debounce: Int  # keystrokes so far: the debounce timer alternates with it; -1 none waiting
    var loading: Bool
    var answered: Bool  # a search reply is in
    var error: String
    var filter: Int
    var results: List[Pick]
    var mem_name: String  # "" none
    var mem_free: Float64
    var mem_total: Float64
    # the notice above the results (too big, needs porting)
    var notice: Int
    var noticed: Pick
    var guided: Bool
    var refused: String
    var sandbox: Bool
    var note: String
    # the setup view
    var setup: Bool
    var running: Bool  # the stages' clock ticks
    var flow: Int  # the run's number (replies for an older one are dropped)
    var aborted: Bool
    var run: Run
    var pull_id: Int
    var port_id: Int
    var waiting: Bool  # a poll is out
    var errors: Int  # polls failed in a row
    var title: String
    var sub: String
    var crumb: String
    var acts: Int  # 0 none, 1 cancel, 2 retry + back ("Try again"), 3 retry + back ("Start again")
    var ready: Bool
    var log_open: Bool
    var pre: List[LogLine]
    var tail: List[LogLine]
    var post: List[LogLine]
    var seen: List[Tuple[String, String]]  # a pull's steps already logged (id, key)
    var copies: Int
    var copied_ep: Bool

    def __init__(out self):
        self.q = ""
        self.seq = 0
        self.debounce = -1
        self.loading = True
        self.answered = False
        self.error = ""
        self.filter = 0
        self.results = List[Pick]()
        self.mem_name = ""
        self.mem_free = 0
        self.mem_total = 0
        self.notice = NOTICE_NONE
        self.noticed = Pick("", "", "", "", -1, -1, -1, "", List[Sugg]())
        self.guided = False
        self.refused = ""
        self.sandbox = False
        self.note = ""
        self.setup = False
        self.running = False
        self.flow = 0
        self.aborted = False
        self.run = Run("pull", Pick("", "", "", "", -1, -1, -1, "", List[Sugg]()), "", "", 0)
        self.pull_id = 0
        self.port_id = 0
        self.waiting = False
        self.errors = 0
        self.title = "Add a model"
        self.sub = DEFAULT_SUB
        self.crumb = "Add a model"
        self.acts = 0
        self.ready = False
        self.log_open = True
        self.pre = List[LogLine]()
        self.tail = List[LogLine]()
        self.post = List[LogLine]()
        self.seen = List[Tuple[String, String]]()
        self.copies = 0
        self.copied_ep = False

    def memory_text(self) -> String:
        if self.mem_name == "":
            return ""
        return self.mem_name + " · " + trim1(self.mem_free) + " GB free of " + trim1(self.mem_total) + " GB"

    def shown(self) -> List[Int]:
        """filterResults: the rows the filter keeps (their places in results)."""
        var out = List[Int]()
        for k in range(len(self.results)):
            var f = self.results[k].fit
            if self.filter == 0 or (self.filter == 1 and (f == "ok" or f == "tight")) or (self.filter == 2 and f == "port"):
                out.append(k)
        return out^

    def hw_detail(self, r: Pick) -> String:
        if r.est_gb < 0 or self.mem_name == "":
            return "size unknown · trying anyway"
        return "needs ~" + trim1(r.est_gb) + " GB · " + trim1(self.mem_free) + " GB free on " + self.mem_name


# ---------- the screen ----------

def fit_chip(fit: String) -> Tuple[String, String]:
    if fit == "ok":
        return ("ok", "fits")
    if fit == "tight":
        return ("tight", "tight fit")
    if fit == "no":
        return ("no", "too big")
    if fit == "port":
        return ("port", "needs porting")
    return ("inst", "size unknown")


def fit_tone(key: String) -> Int:
    """A fit's tone: fits good, tight a warning, won't fit bad, needs porting to do (INFO), unknown quiet."""
    if key == "ok":
        return GOOD
    if key == "tight":
        return WARN
    if key == "no":
        return BAD
    if key == "port":
        return INFO
    return QUIET


def result_row(r: Pick, row: Int) -> View:
    var hf = r.source == "hf"
    var meta = joined([arch_short(r.arch), params_text(r.params), size_text(r.size_gb)])
    var chip = fit_chip(r.fit)
    var repo = r.repo if r.repo != "" else r.id
    return ResultRow("HF" if hf else "MAX", 4 if hf else 3, r.id, ADD_PICK + row, joined([repo if repo != r.id else String(""), meta]), StatusMark(chip[1], fit_tone(chip[0])),
                     ("~" + trim1(r.est_gb) + " GB VRAM") if r.est_gb >= 0 else String(""))


def results_view(a: Add) -> View:
    """The card's list: loading, an error, nothing, or the rows (searchView, drawResults)."""
    var query = String(a.q.strip())
    if a.error != "":
        return EmptyState("triangle-alert", "Search failed", a.error, "Try again", ADD_EMPTY)
    if not a.answered:
        return SkeletonList(4)
    var rows = a.shown()
    if len(rows) == 0:
        if len(a.results) == 0 or query != "":
            var text = ("Nothing matches “" + query + "”. Try a Hugging Face repo id like owner/name.") if query != "" else String("No curated models are listed.")
            if len(a.results) > 0:
                text = "Nothing in this filter."
            return EmptyState("search", "No results", text, "Clear search", ADD_EMPTY) if query != "" else EmptyState("search", "No models listed", text)
        return EmptyState("search", "Nothing in this filter", "Nothing in this filter.", "Show all", ADD_EMPTY)
    var items: List[View] = []
    for k in rows:
        items.append(result_row(a.results[k], k))
    return VStack(items^, spacing=0).align(START).fill().tag("results")


def warn_card(a: Add) -> View:
    """The "this one won't fit" card: need against free, and smaller models to pick instead (warnView)."""
    var r = a.noticed.copy()
    var name = last_part(r.repo if r.repo != "" else r.id)
    var free = a.mem_free if a.mem_name != "" else 0.0
    var gpu = a.mem_name if a.mem_name != "" else String("this machine")
    var pct = min(100.0, free / r.est_gb * 100) if r.est_gb > 0 else 100.0
    var heading = (name + " needs ~" + trim1(r.est_gb) + " GB. You have " + trim1(free) + " GB free.") if r.est_gb > 0 else (name + " will not fit in the " + trim1(free) + " GB you have free.")
    var body: List[View] = [QuietText("omxconsole checks before downloading weights you cannot use. Pick a smaller model that fits, or free memory by stopping a running one."),
                            Meter("needs", 100, True, ("~" + trim1(r.est_gb) + " GB") if r.est_gb > 0 else String("?")),
                            Meter(gpu, Int(pct), False, trim1(free) + " GB")]
    if len(r.suggestions) > 0:
        var picks: List[View] = []
        for k in range(len(r.suggestions)):
            var s = r.suggestions[k].copy()
            picks.append(SuggestionTile([SmallButton(s.repo, ADD_SUGGEST + k, look=TEXT), Text("fits · ~" + trim1(s.est_gb) + " GB").tag("status-good"),
                                         Text(joined([arch_short(s.arch), params_text(s.params), size_text(s.size_gb)])).tag("result-meta"),
                                         Text("$ " + twin("pull", s.id)).tag("result-figure")]))
        body.append(SuggestionRow(picks^))
    else:
        body.append(QuietText("Nothing smaller in the catalog fits either."))
    return Card([CardHead(heading, lead=[IconSquare("triangle-alert", tone=WARN)], tail=[Badge("nothing downloaded", BADGE_WARN, dot=True)]),
                 CardBody(body^), CardFoot("hardware check against " + gpu, note=True)])


def port_card(a: Add) -> View:
    """The port offer: what porting does, the facts, and Port it (or the guided command)."""
    var r = a.noticed.copy()
    var mref = r.repo if r.repo != "" else r.id
    var body: List[View] = [QuietText(PORT_NOTE)]
    if a.guided:
        body.append(WarnLine("Automatic porting is not in this daemon yet. Run the guided port from a terminal instead:"))
    if a.note != "":
        body.append(WarnLine(a.note))
    if a.refused != "":
        body.append(WarnLine(a.refused))
    if a.sandbox:
        body.append(QuietText("Without a sandbox the agent would run with your full permissions, so it is not offered here. If you accept that, the terminal can: "
                              + twin("port", mref) + " --unsandboxed"))
    var size = joined([params_text(r.params), size_text(r.size_gb)])
    body.append(FactList([Fact("architecture", FactText(r.arch if r.arch != "" else String("unknown"))), Fact("size", FactText(size if size != "" else String("unknown"))),
                          Fact("skill", FactText("import-model"))]))
    if a.guided:
        body.append(ButtonRow([SmallButton("Copy the command", ADD_COPY_CMD, "copy")]))
    elif a.refused == "":
        body.append(ButtonRow([SmallButton("Port it", ADD_PORT_IT, "hammer", FILL)]))
    return Card([CardHead(last_part(mref) + " uses " + (r.arch if r.arch != "" else String("an architecture")) + ", which MAX cannot run yet.",
                          lead=[IconSquare("hammer", hue=1)], tail=[Badge("architecture check")]),
                 CardBody(body^), CardFoot(twin("guided", mref) if a.guided or a.refused != "" else twin("port", mref))])


def find_view(a: Add, phone: Bool) -> View:
    var query = String(a.q.strip())
    var items: List[View] = [FieldWithHelp(OutlinedField(a.q, "Search models", ADD_FIELD, ADD_ENTER), "Search the MAX catalog, or paste a Hugging Face repo id (owner/name)"),
                             FilterChips(materialize[FILTER_TITLES](), a.filter, ADD_FILTER)]
    if a.notice == NOTICE_WARN:
        items.append(warn_card(a))
    elif a.notice == NOTICE_PORT:
        items.append(port_card(a))
    var title = String("Results")
    if a.answered and a.error == "" and len(a.results) > 0:
        title = (String(len(a.results)) + " result" + ("" if len(a.results) == 1 else "s")) if query != "" else String("Curated models")
    var mem = a.memory_text()
    items.append(Card([CardHead(title), results_view(a), CardFoot(twin("search", query) if query != "" else String("mxc search <query>"),
                                                                  tail=("fit checked against " + mem) if mem != "" else String(""))]))
    return PageColumn(items^, compact=phone)


def ready_card(a: Add, name: String, endpoint: String) -> View:
    return Card([CardHead(name + " is serving.", tail=[Badge("ready · localhost", BADGE_OK, dot=True)]),
                 CardBody([CopyRow("local", endpoint, ADD_COPY_EP, "Copied" if a.copied_ep else "Copy"),
                           CodeBlock(chat_curl(endpoint, name, "Hello", spaced=True), on_copy=ADD_COPY_CURL, copies=a.copies, copied=a.copies > 0, title="Copy curl").fill(),
                           QuietText("It is on localhost only. Make it secure to reach it from your phone or another machine with HTTPS and an API key."),
                           ButtonRow([SmallButton("Open", ADD_OPEN, "chevron-right", FILL), SmallButton("Make it secure", ADD_SECURE, "lock"),
                                      SmallButton("Add another", ADD_ANOTHER, "plus", TEXT)])]),
                 CardFoot(twin("serve", name))])


def setup_view(a: Add, now: Float64, phone: Bool) -> View:
    """Stages on the left, the live log on the right (below on a phone)."""
    var left: List[View] = [Card([CardBody([Timeline(setup_stages(a.run, now))]), CardFoot(a.sub)])]
    if a.acts == 1:
        left.append(ButtonRow([SmallButton("Cancel", ADD_CANCEL, "x")]))
    elif a.acts >= 2:
        left.append(ButtonRow([SmallButton("Try again" if a.acts == 2 else "Start again", ADD_RETRY, "refresh-cw", FILL), SmallButton("Back to search", ADD_TO_SEARCH, "search")]))
    if a.ready:
        left.append(ready_card(a, a.run.name, a.run.endpoint))
    var lines = a.pre.copy()
    lines += a.tail.copy()
    lines += a.post.copy()
    var pane = LogPane("LIVE LOG", lines, a.log_open, ADD_LOG, 0).grow()
    return MainAside(CardColumn(left^), pane^, aside_wide=a.log_open, compact=phone)


def add_page(a: Add, now: Float64, phone: Bool) -> View:
    var header = PageHeader("plus", a.title, "", a.sub, List[View](), hue=3, lead=[BackButton(ADD_BACK)])
    var body: View
    if a.setup:
        body = setup_view(a, now, phone)
        if phone:
            body = Scroll(body^, height=0).grow().fill()
    else:
        body = Scroll(find_view(a, phone), height=0).grow().fill()
    return PageCard([header^, Divider().fill(), body^])
