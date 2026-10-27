# The console's data: the daemon's /admin/* replies read into plain values, and the original's formatting rules
# (core.js fmt, dur, dateTime; library-logic.js sizeLabel; hardware.js; blade-home.js modelView; model-page.js fitView).
# Pure: no views, no requests. Every screen reads a Store.

from mojoui.json import Json, J_NULL, J_NUMBER, J_STRING, J_ARRAY, J_OBJECT, J_BOOL
from mojoui.shared import floored
from mojoui.numformat import rounded, round1, en_number, duration_short, byte_size


@fieldwise_init
struct Model(Copyable, Movable):
    var name: String
    var repo: String
    var source: String
    var arch: String
    var pinned: Bool
    var keep_alive: Float64  # seconds; 0: none
    var kind: String
    var size_bytes: Float64  # 0: unknown
    var labels: List[String]
    var state: String  # ready, starting, cold, crashed
    var idle_seconds: Float64  # -1: none
    var starting_seconds: Float64  # -1: none


@fieldwise_init
struct ByModel(Copyable, Movable):
    var name: String
    var requests: Int  # -1: none
    var ttft: Float64  # -1: none
    var tps: Float64  # -1: none


@fieldwise_init
struct Series(Copyable, Movable):
    var name: String
    var points: List[Float64]  # decode tok/s p50 per bucket, the empty buckets left out


@fieldwise_init
struct BenchResult(Copyable, Movable):
    var model: String
    var status: String
    var decode_tps: Float64
    var ttft: Float64
    var completion_tokens: Int
    var estimated: Bool
    var error: String


@fieldwise_init
struct BenchRun(Copyable, Movable):
    var id: Int
    var started_at: Float64
    var status: String
    var runs: Int
    var max_tokens: Int
    var prompt_tokens: Int
    var models: Int
    var results: List[BenchResult]


@fieldwise_init
struct Cell(Copyable, Movable):
    var code: Bool
    var source: String
    var count: Int  # the saved execution count; -1: never run
    var outputs: List[String]


@fieldwise_init
struct ArchRow(Copyable, Movable):
    var field: String
    var value: String


struct Store(Copyable, Movable):
    """What the polls brought back (core.js store, system-data.js, beacon.js jobs, library labels)."""

    var loaded: Bool  # /admin/models answered at least once
    var error: String  # the last core poll failed ("" fine)
    var models: List[Model]
    var by_model: List[ByModel]
    var series: List[Series]
    var gpu_name: String  # "" no GPU
    var gpu_used_mb: Float64
    var gpu_total_mb: Float64
    var endpoint: String
    var lan_endpoint: String
    var crew: List[Tuple[String, Float64]]  # (model name, vram GB > 0)
    var labels: List[String]
    var pull_name: String  # a running pull ("" none)
    var pull_percent: Float64  # -1 unknown
    var port_name: String
    var port_step: String

    def __init__(out self):
        self.loaded = False
        self.error = ""
        self.models = List[Model]()
        self.by_model = List[ByModel]()
        self.series = List[Series]()
        self.gpu_name = ""
        self.gpu_used_mb = 0
        self.gpu_total_mb = 0
        self.endpoint = ""
        self.lan_endpoint = ""
        self.crew = List[Tuple[String, Float64]]()
        self.labels = List[String]()
        self.pull_name = ""
        self.pull_percent = -1
        self.port_name = ""
        self.port_step = ""

    def model(self, name: String) -> Int:
        for k in range(len(self.models)):
            if self.models[k].name == name:
                return k
        return -1

    def stats(self, name: String) -> ByModel:
        for b in self.by_model:
            if b.name == name:
                return b.copy()
        return ByModel(name, -1, -1, -1)

    def points(self, name: String) -> List[Float64]:
        for s in self.series:
            if s.name == name:
                return s.points.copy()
        return List[Float64]()

    def vram(self, name: String) -> Float64:
        """This model's GPU memory, rounded to 0.1 GB (-1: unknown)."""
        for c in self.crew:
            if c[0] == name:
                return round1(c[1])
        return -1

    def endpoint_now(self) -> String:
        return self.endpoint if self.endpoint != "" else String("http://127.0.0.1:11435/v1")


# ---------- reading replies ----------

def real_or(j: Json, node: Int, default: Float64) -> Float64:
    return j.real(node) if j.kind(node) == J_NUMBER else default


def read_models(text: String, mut st: Store) raises:
    var j = Json.parse(text)
    var out = List[Model]()
    for i in range(j.size(0)):
        var m = j.at(0, i)
        var labels = List[String]()
        var ls = j.get(m, "labels")
        for k in range(j.size(ls)):
            labels.append(j.text(j.at(ls, k)))
        out.append(Model(j.text(j.get(m, "name")), j.text(j.get(m, "repo_id")), j.text(j.get(m, "source")), j.text(j.get(m, "architecture")),
                         j.flag(j.get(m, "pinned")), real_or(j, j.get(m, "keep_alive"), 0), j.text(j.get(m, "kind")),
                         real_or(j, j.get(m, "size_bytes"), 0), labels^, j.text(j.get(m, "state")),
                         real_or(j, j.get(m, "idle_seconds"), -1), real_or(j, j.get(m, "starting_seconds"), -1)))
    st.models = out^
    st.loaded = True


def read_metrics(text: String, mut st: Store) raises:
    var j = Json.parse(text)
    var by = j.get(0, "by_model")
    var out = List[ByModel]()
    for k in range(j.size(by)):
        var b = j.at(by, k)
        var req = j.get(b, "requests")
        out.append(ByModel(j.keys[by][k], j.number(req) if j.kind(req) == J_NUMBER else -1, real_or(j, j.get(b, "ttft_p50_ms"), -1),
                           real_or(j, j.get(b, "decode_tps_p50"), -1)))
    st.by_model = out^
    var gpus = j.get(0, "gpus")
    if j.size(gpus) > 0:
        var g = j.at(gpus, 0)
        st.gpu_name = j.text(j.get(g, "name"))
        st.gpu_used_mb = real_or(j, j.get(g, "used_mb"), 0)
        st.gpu_total_mb = real_or(j, j.get(g, "total_mb"), 0)
    else:
        st.gpu_name = ""


def read_series(text: String, mut st: Store) raises:
    var j = Json.parse(text)
    var models = j.get(0, "models")
    var out = List[Series]()
    for k in range(j.size(models)):
        var pts = List[Float64]()
        var b = j.at(models, k)
        for i in range(j.size(b)):
            var v = j.get(j.at(b, i), "decode_tps_p50")
            if j.kind(v) == J_NUMBER:
                pts.append(j.real(v))
        out.append(Series(j.keys[models][k], pts^))
    st.series = out^


def read_info(text: String, mut st: Store) raises:
    var j = Json.parse(text)
    st.endpoint = j.text(j.get(0, "endpoint"))
    st.lan_endpoint = j.text(j.get(0, "lan_endpoint"))


def read_system(text: String, mut st: Store) raises:
    var j = Json.parse(text)
    var crew = j.get(0, "crew")
    var out = List[Tuple[String, Float64]]()
    for k in range(j.size(crew)):
        var c = j.at(crew, k)
        var id = j.text(j.get(c, "id"))
        var gb = real_or(j, j.get(c, "vram_gb"), 0)
        if id.startswith("model:") and gb > 0:
            out.append((String(id[byte=6:]), gb))
    st.crew = out^


def read_labels(text: String, mut st: Store) raises:
    var j = Json.parse(text)
    var out = List[String]()
    for k in range(j.size(0)):
        out.append(j.text(j.get(j.at(0, k), "name")))
    st.labels = out^


def read_pulls(text: String, mut st: Store) raises:
    var j = Json.parse(text)
    var pulls = j.get(0, "pulls")
    st.pull_name = ""
    for k in range(j.size(pulls)):
        var p = j.at(pulls, k)
        if j.text(j.get(p, "status")) == "running":
            var name = j.text(j.get(p, "name"))
            st.pull_name = name if name != "" else j.text(j.get(p, "ref"))
            st.pull_percent = real_or(j, j.get(p, "percent"), -1)
            return


def read_ports(text: String, mut st: Store) raises:
    var j = Json.parse(text)
    var ports = j.get(0, "ports")
    st.port_name = ""
    for k in range(j.size(ports)):
        var p = j.at(ports, k)
        if j.text(j.get(p, "status")) == "running":
            var name = j.text(j.get(p, "name"))
            st.port_name = name if name != "" else j.text(j.get(p, "ref"))
            return


def read_run(j: Json, r: Int) -> BenchRun:
    var results = List[BenchResult]()
    var rs = j.get(r, "results")
    for k in range(j.size(rs)):
        var x = j.at(rs, k)
        var ct = j.get(x, "completion_tokens")
        results.append(BenchResult(j.text(j.get(x, "model")), j.text(j.get(x, "status")), real_or(j, j.get(x, "decode_tps"), 0),
                                   real_or(j, j.get(x, "ttft_p50_ms"), 0), j.number(ct) if j.kind(ct) == J_NUMBER else 0,
                                   j.flag(j.get(x, "estimated")), j.text(j.get(x, "error"))))
    return BenchRun(j.number(j.get(r, "id")), real_or(j, j.get(r, "started_at"), 0), j.text(j.get(r, "status")), j.number(j.get(r, "runs")),
                    j.number(j.get(r, "max_tokens")), j.number(j.get(r, "prompt_tokens")), j.size(j.get(r, "models")), results^)


def json_value(j: Json, node: Int) -> String:
    """A config value as the notebook shows it (JavaScript's String(v): 1000000.0 is 1000000, true is true)."""
    var k = j.kind(node)
    if k == J_STRING:
        return j.text(node)
    if k == J_BOOL:
        return "true" if j.flag(node) else "false"
    if k == J_NULL:
        return "null"
    if k == J_NUMBER:
        var v = j.real(node)
        if v == floored(v) and abs(v) < 1e15:
            return String(Int(v))
        return String(v)
    return "…"


# ---------- formatting: mojoui.numformat (rounded, en_number, duration_short, byte_size, utc_date_time) ----------

def short_endpoint(url: String) -> String:
    if url.startswith("http://"):
        return String(url[byte=7:])
    if url.startswith("https://"):
        return String(url[byte=8:])
    return url


def compact(n: Float64) -> String:
    """blade-notebook.js compact: 494 M, 136.1 M, 1.2 B."""
    if n >= 1e9:
        return en_number(n / 1e9, 2) + " B"
    if n >= 1e6:
        return en_number(n / 1e6, 1) + " M"
    return en_number(n)


# ---------- the original's views of the data ----------

@fieldwise_init
struct Row(Copyable, Movable):
    """One model as My models shows it (blade-home.js modelView + cellsFor)."""
    var name: String
    var repo: String
    var running: Bool
    var state_label: String
    var note: String
    var arch: String
    var kind: String
    var labels: List[String]
    var size: String
    var memory: String
    var tps: String
    var ttft: String
    var requests: String
    var access: String
    var tps_value: Float64  # -1: none
    var ttft_value: Float64
    var requests_value: Int
    var vram: Float64


def state_label(state: String) -> String:
    if state == "ready":
        return "Running"
    if state == "starting":
        return "Starting"
    if state == "crashed":
        return "Crashed"
    return "Idle"


def strip_arch(a: String) -> String:
    for tail in ["ForCausalLM", "ForConditionalGeneration", "LMHeadModel"]:
        if a.endswith(tail):
            return String(a[byte = : a.byte_length() - tail.byte_length()])
    return a if a != "" else String("—")


def row_of(st: Store, m: Model) -> Row:
    var running = m.state == "ready"
    var by = st.stats(m.name)
    var pts = st.points(m.name)
    var live = pts[len(pts) - 1] if len(pts) > 0 else by.tps
    var note = String("")
    if m.state == "starting":
        note = ("compiling · " + duration_short(m.starting_seconds)) if m.starting_seconds >= 0 else String("starting")
    elif m.pinned:
        note = "pinned"
    elif running and m.idle_seconds >= 0 and m.keep_alive > 0:
        note = "idle " + duration_short(m.idle_seconds) + " of " + duration_short(m.keep_alive)
    var tps = rounded(live, 0) if running and live >= 0 else -1.0
    var ttft = by.ttft if running and by.ttft >= 0 else -1.0
    var req = by.requests if by.requests >= 0 else (0 if running else -1)
    var vram = st.vram(m.name)
    return Row(m.name, m.repo, running, state_label(m.state), note, strip_arch(m.arch), m.kind, m.labels.copy(), byte_size(m.size_bytes),
               (en_number(vram, 1) + " GB") if vram > 0 else String("–"), en_number(tps) if tps >= 0 else String("–"),
               (en_number(ttft) + " ms") if ttft >= 0 else String("–"), en_number(Float64(req)) if req >= 0 else String("–"),
               "Secure · LAN" if st.lan_endpoint != "" else "This machine", tps, ttft, req, vram)


def rank(state: String) -> Int:
    if state == "ready":
        return 0
    if state == "starting":
        return 1
    if state == "crashed":
        return 2
    return 3


def sorted_models(st: Store) -> List[Model]:
    """Running first, then starting, crashed, the rest; by name within each (library-logic.js byState)."""
    var out = st.models.copy()
    for i in range(1, len(out)):
        var j = i
        while j > 0 and (rank(out[j].state) < rank(out[j - 1].state) or (rank(out[j].state) == rank(out[j - 1].state) and out[j].name < out[j - 1].name)):
            var t = out[j].copy()
            out[j] = out[j - 1].copy()
            out[j - 1] = t^
            j -= 1
    return out^


comptime KINDS: List[String] = ["chat", "coder", "vision", "embeddings", "image"]
comptime KIND_NAMES: List[String] = ["Chat", "Coder", "Vision", "Embeddings", "Image"]
comptime KIND_HUES: List[Int] = [1, 4, 2, 3, 8]  # library.js KIND_COLOUR: data-1, data-4, data-2, data-3, warn (HueDot's 8)


def kind_name(k: String) -> String:
    var ks = materialize[KINDS]()
    for i in range(len(ks)):
        if ks[i] == k:
            return materialize[KIND_NAMES]()[i]
    return k


def kind_hue(k: String) -> Int:
    var ks = materialize[KINDS]()
    for i in range(len(ks)):
        if ks[i] == k:
            return materialize[KIND_HUES]()[i]
    return 0


@fieldwise_init
struct Hardware(Copyable, Movable):
    var present: Bool
    var short: String
    var used_gb: Float64
    var total_gb: Float64


def hardware(st: Store) -> Hardware:
    """hardware.js hardwareView: the first GPU in GB (MiB / 1024), rounded to 0.1."""
    if st.gpu_name == "" or st.gpu_total_mb <= 0:
        return Hardware(False, "", 0, 0)
    var short = st.gpu_name
    if short.startswith("NVIDIA "):
        var rest = String(short[byte=7:])
        short = rest^
    if short.startswith("GeForce "):
        var rest = String(short[byte=8:])
        short = rest^
    return Hardware(True, short, round1(st.gpu_used_mb / 1024), round1(st.gpu_total_mb / 1024))
