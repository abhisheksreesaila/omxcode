# consoled's read-only admin replies, as docs/goals/50/admin-api-spec.md §4 describes the Python daemon's: the store's
# rows come out of SQLite as JSON; the rest (system, metrics, series) is computed here.

from std.os import getenv, listdir
from std.os.path import exists, isdir, join
from std.math import floor
from mojoui.sqlite import Database
from mojoui.json import Json, json_string, J_ARRAY, J_OBJECT, J_STRING, J_NUMBER, J_NULL
from mojoui.process import file_tail
from mojoui.clock import wall_seconds
from mojoui import libc
from mojoui.libc import _sym
from store import Store
from expose import expose_port
from portprep import workspace_name, package_slug
from supervisor import Supervisor, gpus, gpus_json, Gpu
from sysinfo import hostname, rss_mb, tree_bytes


def rnd(x: Float64, digits: Int) -> Float64:
    var p = 1.0
    for _ in range(digits):
        p *= 10
    var v = x * p
    var r = floor(v + 0.5)
    if r - v == 0.5 and Int(r) % 2 != 0:  # (a tie: to even, as Python's round)
        r -= 1
    return r / p


def num(x: Float64) -> String:
    """A float as Python's JSON writes one (a whole one keeps its .0)."""
    var s = String(x)
    if s.find(".") < 0 and s.find("e") < 0 and s.find("n") < 0:
        s += ".0"
    return s


def opt(x: Float64, digits: Int) -> String:
    """null for NaN (no value), else the rounded number."""
    if x != x:
        return "null"
    return num(rnd(x, digits))


def local_midnight() -> Float64:
    """Today's start in local time (the original's "today"); from the clock's offset to UTC via localtime_r."""
    var now = Int(wall_seconds())
    var tm = List[Int32](length=16, fill=0)
    var t = List[Int](length=1, fill=now)
    var f = Int(0)
    try:
        f = _localtime_r()
    except:
        pass
    if f == 0:
        return Float64(now - now % 86400)
    _ = Pointer(to=f).unsafe_bitcast[def(Int, Int) thin abi("C") -> Int]()[](Int(t.unsafe_ptr()), Int(tm.unsafe_ptr()))
    var sec = Int(tm[0])
    var minute = Int(tm[1])
    var hour = Int(tm[2])
    return Float64(now - sec - minute * 60 - hour * 3600)


def _localtime_r() raises -> Int:
    return _sym("localtime_r")


# models ---------------------------------------------------------------------------------------------------------

def models_json(store: Store, mut sup: Supervisor, sizes: Dict[String, Int]) raises -> String:
    var rows = store.db.one_text("""SELECT coalesce(json_group_array(json_object('name', name, 'repo_id', repo_id, 'revision', revision,
        'source', source, 'architecture', architecture, 'pinned', json(CASE WHEN pinned != 0 THEN 'true' ELSE 'false' END),
        'keep_alive', keep_alive, 'kind', kind, 'weights_path', weights_path,
        'labels', (SELECT coalesce(json_group_array(label), '[]') FROM (SELECT label FROM model_labels WHERE model = m.name ORDER BY label)))), '[]')
        FROM (SELECT * FROM models ORDER BY name) m""")
    var j = Json.parse(rows)
    var out = String("[")
    for i in range(j.size(0)):
        var m = j.at(0, i)
        var name = j.text(j.get(m, "name"))
        var path = j.text(j.get(m, "weights_path"))
        var size = sizes.get(path, -1)
        var c = sup.find(name)
        var state = String("cold")
        var port = String("null")
        var idle = String("null")
        var starting = String("null")
        var flight = 0
        if c >= 0:
            state = sup.state(name)
            port = String(sup.children[c].port)
            flight = sup.children[c].in_flight
            if state == "ready":
                idle = num(Float64(sup.children[c].proc.idle_ms()) / 1000)
            else:
                starting = num(Float64(sup.children[c].proc.uptime_ms()) / 1000)
        out += (", " if i > 0 else "") + '{"name": ' + json_string(name) + ', "repo_id": ' + json_string(j.text(j.get(m, "repo_id")))
        out += ', "revision": ' + json_string(j.text(j.get(m, "revision"))) + ', "source": ' + json_string(j.text(j.get(m, "source")))
        out += ', "architecture": ' + json_string(j.text(j.get(m, "architecture"))) + ', "pinned": ' + ("true" if j.flag(j.get(m, "pinned")) else "false")
        out += ', "keep_alive": ' + String(j.number(j.get(m, "keep_alive"))) + ', "kind": ' + json_string(j.text(j.get(m, "kind")))
        out += ', "size_bytes": ' + (String(size) if size > 0 else "null") + ', "labels": ' + list_json(j, j.get(m, "labels"))
        out += ', "state": ' + json_string(state) + ', "port": ' + port + ', "idle_seconds": ' + idle + ', "starting_seconds": ' + starting
        out += ', "in_flight": ' + String(flight) + "}"
    return out + "]"


def list_json(j: Json, node: Int) -> String:
    var out = String("[")
    for k in range(j.size(node)):
        out += (", " if k > 0 else "") + json_string(j.text(j.at(node, k)))
    return out + "]"


def model_sizes(store: Store) raises -> Dict[String, Int]:
    """size_bytes per weights_path (spec §3.5: every file under the folder, links followed), measured once."""
    var out = Dict[String, Int]()
    var q = store.db.prepare("SELECT coalesce(weights_path, '') FROM models")
    while q.step():
        var p = q.text(0)
        if p != "" and p not in out:
            out[p] = tree_bytes(p)
    return out^


# info, gateway, network, system ---------------------------------------------------------------------------------

def max_version() -> String:
    """MAX's version from the pixi env that runs `max` (conda-meta/max-*.json, or the PyPI dist-info's name)."""
    var prefix = getenv("CONDA_PREFIX")
    if prefix == "":
        return "null"
    try:
        var meta = prefix + "/conda-meta"
        if isdir(meta):
            for f in listdir(meta):
                if f.startswith("max-") and f.endswith(".json") and f.byte_length() > 5 and f.as_bytes()[4] >= 48 and f.as_bytes()[4] <= 57:
                    var parts = String(f[byte = : f.byte_length() - 5]).split("-")
                    if len(parts) >= 2:
                        return json_string(String(parts[1]))
        var site = prefix + "/lib"
        for py in listdir(site):
            if py.startswith("python"):
                var sp = site + "/" + py + "/site-packages"
                if isdir(sp):
                    for f in listdir(sp):
                        if f.startswith("max-") and f.endswith(".dist-info"):
                            return json_string(String(f[byte = 4 : f.byte_length() - 10]))
    except:
        pass
    return "null"


def find_max(max_cmd: String) -> String:
    """Where `max` runs from ("" when it isn't installed): MXC_MAX's path, or the first `max` on PATH."""
    var first = String(max_cmd.split(" ")[0]) if max_cmd != "" else String("max")
    if first.find("/") >= 0:
        return first if exists(first) else String("")
    for d in getenv("PATH").split(":"):
        var p = String(d) + "/" + first
        if String(d) != "" and exists(p):
            return p
    return ""


def info_json(store: Store, port: Int, host_header: String, uptime: Int, max_cmd: String = "max", lan: String = "") raises -> String:
    var base = "http://" + (host_header if host_header != "" else "127.0.0.1")
    var active = store.db.count("SELECT COUNT(*) FROM keys WHERE revoked_at IS NULL AND app NOT LIKE '\\_%' ESCAPE '\\'")
    var blocked = atol(store.db.one_text("SELECT COUNT(*) FROM requests WHERE status = 401 AND ts >= ?", [String(local_midnight())]))
    return ('{"host": ' + json_string(hostname()) + ', "endpoint": ' + json_string(base + "/v1") + ', "docs": ' + json_string(base + "/docs")
            + ', "lan_endpoint": ' + (json_string(lan) if lan != "" else "null") + ', "max_version": ' + max_version() + ', "uptime_seconds": ' + String(uptime)
            + ', "active_keys": ' + String(active) + ', "blocked_today": ' + String(blocked)
            + ', "max": {"found": ' + ("true" if find_max(max_cmd) != "" else "false") + ', "path": ' + json_string(find_max(max_cmd)) + "}}")


def gateway_json(store: Store, since: Float64, unknown: Int, refused: Int, lan: String = "") raises -> String:
    var active = store.db.count("SELECT COUNT(*) FROM keys WHERE revoked_at IS NULL AND app NOT LIKE '\\_%' ESCAPE '\\'")
    var revoked = store.db.count("SELECT COUNT(*) FROM keys WHERE revoked_at IS NOT NULL AND app NOT LIKE '\\_%' ESCAPE '\\'")
    var unauth = atol(store.db.one_text("SELECT COUNT(*) FROM requests WHERE status = 401 AND ts >= ?", [String(local_midnight())]))
    return ('{"counters_since": ' + num(since) + ', "tls": {"on": ' + ("true" if lan != "" else "false") + ', "endpoint": '
            + (json_string(lan) if lan != "" else "null") + '}, "keys": {"active": ' + String(active)
            + ', "revoked": ' + String(revoked) + '}, "unauthorized_today": ' + String(unauth) + ', "unknown_routes_today": ' + String(unknown)
            + ', "admin_refused_today": ' + String(refused) + ', "enforced_by_caddy": ["dot_segments", "secrets"]}')


def ca_path() -> String:
    var data = getenv("XDG_DATA_HOME", getenv("HOME") + "/.local/share")
    return data + "/caddy/pki/authorities/local/root.crt"


def network_json(store: Store, mut sup: Supervisor, port: Int, lan: String = "") raises -> String:
    var now = wall_seconds()
    var recent = Dict[String, Int]()
    var total_recent = 0
    var q = store.db.prepare("SELECT coalesce(model, ''), COUNT(*) FROM requests WHERE ts >= ? GROUP BY model")
    q.bind(1, now - 60)
    while q.step():
        recent[q.text(0)] = q.int(1)
        total_recent += q.int(1)
    var models = String("[")
    var names = store.db.prepare("SELECT name FROM models ORDER BY name")
    var first = True
    while names.step():
        var n = names.text(0)
        var c = sup.find(n)
        models += ("" if first else ", ") + '{"name": ' + json_string(n) + ', "state": ' + json_string(sup.state(n) if c >= 0 else String("cold"))
        models += ', "port": ' + (String(sup.children[c].port) if c >= 0 else String("null")) + ', "recent": ' + String(recent.get(n, 0)) + "}"
        first = False
    models += "]"
    var apps = store.db.one_text("""SELECT coalesce(json_group_array(json_object('app', app, 'requests', requests, 'last_ts', last_ts)), '[]') FROM (
        SELECT app, COUNT(*) AS requests, MAX(ts) AS last_ts FROM requests WHERE ts >= ? AND app IS NOT NULL
        AND app NOT LIKE '\\_%' ESCAPE '\\' AND app != 'console' GROUP BY app ORDER BY last_ts DESC LIMIT 8)""", [String(now - 86400)])
    var host = hostname()
    return ('{"host": ' + json_string(host) + ', "expose": {"caddy": ' + ("true" if lan != "" else "false") + ', "litellm": false}, "exposed": '
            + ("true" if lan != "" else "false") + ', "lan_endpoint": ' + (json_string(lan) if lan != "" else "null") + ', "default_host": '
            + json_string(host + ".local") + ', "ca_path": ' + json_string(ca_path()) + ', "ca_exists": ' + ("true" if exists(ca_path()) else "false")
            + ', "ports": {"daemon": ' + String(port) + ', "litellm": 4000, "caddy": 8443}, "models": ' + models + ', "apps": ' + apps
            + ', "recent_requests": ' + String(total_recent) + "}")


def system_json(store: Store, mut sup: Supervisor, home: String, port: Int, uptime: Int, lan: String = "") raises -> String:
    var me = libc.getpid()
    var crew = String('[{"id": "daemon", "kind": "daemon", "name": "omxconsole daemon", "state": "running", "pid": ') + String(me)
    crew += ', "port": ' + String(port) + ', "rss_mb": ' + num(rss_mb(me)) + ', "uptime_seconds": ' + String(uptime) + "}"
    crew += ', {"id": "caddy", "kind": "caddy", "name": "Caddy", "state": ' + ('"running"' if lan != "" else '"stopped"') + ', "pid": null, "port": ' + String(expose_port()) + ', "rss_mb": null, "uptime_seconds": null}'
    var listeners = String('[{"name": "omxconsole daemon", "kind": "daemon", "host": "127.0.0.1", "port": ') + String(port)
    listeners += ', "exposed": false, "state": "listening", "talks_to": "the mxc CLI, this console, your apps on this machine, and Caddy (key check, then every LAN request)"}'
    var caddy_state = '"listening"' if lan != "" else '"off"'
    listeners += ', {"name": "Caddy", "kind": "caddy", "host": "0.0.0.0", "port": ' + String(expose_port()) + ', "exposed": true, "state": ' + caddy_state + ', "talks_to": "LAN clients over HTTPS, each with an app key"}'
    listeners += ', {"name": "Caddy admin", "kind": "caddy", "host": "127.0.0.1", "port": 2099, "exposed": false, "state": ' + caddy_state + ', "talks_to": "Caddy itself (its config API)"}'
    for i in range(len(sup.children)):
        var name = sup.children[i].name
        var state = sup.state(name)
        ref c = sup.children[i]
        crew += ', {"id": ' + json_string("model:" + name) + ', "kind": "model", "name": ' + json_string(name) + ', "state": ' + json_string(state)
        crew += ', "pid": ' + String(c.proc.pid) + ', "port": ' + String(c.port) + ', "rss_mb": ' + num(rss_mb(c.proc.pid))
        crew += ', "uptime_seconds": ' + String(c.proc.uptime_ms() // 1000) + ', "vram_gb": null}'
        listeners += ', {"name": ' + json_string("max serve · " + name) + ', "kind": "model", "host": "127.0.0.1", "port": ' + String(c.port)
        listeners += ', "exposed": false, "state": ' + json_string("listening" if state == "ready" else state) + ', "talks_to": "the daemon only"}'
    var logs = String("[")
    var first = True
    if exists(home + "/logs/daemon.log"):
        logs += '{"id": "daemon", "label": "Daemon"}'
        first = False
    var names = store.db.prepare("SELECT name FROM models ORDER BY name")
    while names.step():
        logs += ("" if first else ", ") + '{"id": ' + json_string("model:" + names.text(0)) + ', "label": ' + json_string(names.text(0)) + "}"
        first = False
    logs += "]"
    var list = gpus()
    var gl = String("[")
    var tot = 0.0
    var used = 0.0
    var gname = String("")
    var distinct = List[String]()
    for i in range(len(list)):
        var t = rnd(Float64(list[i].total_mb) / 1024, 1)
        var u = rnd(Float64(list[i].used_mb) / 1024, 1)
        tot += t
        used += u
        gl += (", " if i > 0 else "") + '{"index": ' + String(list[i].index) + ', "name": ' + json_string(list[i].name) + ', "vram_total_gb": ' + num(t) + ', "vram_used_gb": ' + num(u) + "}"
        if list[i].name not in distinct:
            distinct.append(list[i].name)
    gl += "]"
    var gpu = String("null")
    if len(list) > 0:
        if len(distinct) > 1:
            for k in range(len(distinct)):
                gname += (", " if k > 0 else "") + distinct[k]
        else:
            gname = distinct[0] + (" x" + String(len(list)) if len(list) > 1 else "")
        gpu = '{"name": ' + json_string(gname) + ', "count": ' + String(len(list)) + ', "vram_total_gb": ' + num(rnd(tot, 1)) + ', "vram_used_gb": ' + num(rnd(used, 1)) + "}"
    return '{"crew": ' + crew + '], "listeners": ' + listeners + '], "home": ' + json_string(home) + ', "logs": ' + logs + ', "gpu": ' + gpu + ', "gpus": ' + gl + "}"


# metrics and series ---------------------------------------------------------------------------------------------

@fieldwise_init
struct Row(Copyable, Movable):
    var ts: Float64
    var model: String
    var status: Int
    var ttft: Float64  # NaN: none
    var duration: Float64
    var completion: Int  # -1: none


def rows_since(store: Store, since: Float64, models_only: Bool) raises -> List[Row]:
    var out = List[Row]()
    var q = store.db.prepare("SELECT ts, coalesce(model, ''), status, ttft_ms, duration_ms, completion_tokens, model IS NULL FROM requests WHERE ts >= ?" + (" AND model IS NOT NULL" if models_only else ""))
    q.bind(1, since)
    var nan = Float64(0) / Float64(0)
    while q.step():
        out.append(Row(q.float(0), q.text(1), q.int(2), nan if q.is_null(3) else q.float(3), q.float(4), -1 if q.is_null(5) else q.int(5)))
    return out^


def pct(var v: List[Float64], p: Float64) -> Float64:
    if len(v) == 0:
        return Float64(0) / Float64(0)
    sort(v)
    var k = Float64(len(v) - 1) * p
    var lo = Int(floor(k))
    var hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - Float64(lo))


def stats(rows: List[Row], p95: Bool = True) -> String:
    var errors = 0
    var ttft = List[Float64]()
    var tps = List[Float64]()
    for r in rows:
        if r.status >= 400:
            errors += 1
            continue
        if r.ttft == r.ttft:
            ttft.append(r.ttft)
            if r.completion >= 2 and r.duration - r.ttft > 0:
                tps.append(Float64(r.completion - 1) / ((r.duration - r.ttft) / 1000))
    return ('"requests": ' + String(len(rows)) + ', "errors": ' + String(errors) + ', "ttft_p50_ms": ' + opt(pct(ttft.copy(), 0.5), 1)
            + (', "ttft_p95_ms": ' + opt(pct(ttft^, 0.95), 1) if p95 else String("")) + ', "decode_tps_p50": ' + opt(pct(tps^, 0.5), 1))


def window_of(rng: String) -> Int:
    if rng == "5m":
        return 300
    if rng == "1h":
        return 3600
    if rng == "24h":
        return 86400
    if rng == "7d":
        return 604800
    return -1


def metrics_json(store: Store, rng: String) raises -> String:
    var window = window_of(rng)
    var rows = rows_since(store, wall_seconds() - Float64(window), False)
    var names = List[String]()
    for r in rows:
        if r.model != "" and r.model not in names:
            names.append(r.model)
    sort(names)
    var by = String("{")
    for i in range(len(names)):
        var mine = List[Row]()
        for r in rows:
            if r.model == names[i]:
                mine.append(r.copy())
        by += (", " if i > 0 else "") + json_string(names[i]) + ": {" + stats(mine) + "}"
    by += "}"
    var errors = 0
    for r in rows:
        if r.status >= 400:
            errors += 1
    var n = len(rows)
    return ("{" + stats(rows) + ', "window_seconds": ' + String(window) + ', "per_minute": ' + num(rnd(Float64(n) / (Float64(window) / 60), 2))
            + ', "error_rate": ' + (num(rnd(Float64(errors) / Float64(n), 3)) if n > 0 else "0.0") + ', "by_model": ' + by
            + ', "gpus": ' + gpus_json(gpus()) + "}")


def series_json(store: Store, rng: String) raises -> String:
    var span = window_of(rng)
    var step = 10 if rng == "5m" else (60 if rng == "1h" else (1800 if rng == "24h" else 10800))
    var count = span // step
    var now = Int(wall_seconds())
    var first = (now // step - count + 1) * step
    var rows = rows_since(store, Float64(first), True)
    var names = List[String]()
    for r in rows:
        if r.model not in names:
            names.append(r.model)
    sort(names)
    var buckets = String("[")
    for i in range(count):
        buckets += (", " if i > 0 else "") + String(first + i * step)
    buckets += "]"
    var models = String("{")
    for m in range(len(names)):
        models += (", " if m > 0 else "") + json_string(names[m]) + ": ["
        for i in range(count):
            var mine = List[Row]()
            for r in rows:
                var b = Int(r.ts - Float64(first)) // step
                if r.model == names[m] and b == i:
                    mine.append(r.copy())
            var ok = 0
            for r in mine:
                if r.status < 400:
                    ok += 1
            models += (", " if i > 0 else "") + '{"t": ' + String(first + i * step) + ", " + stats(mine, False) + ', "ok": ' + String(ok) + "}"
        models += "]"
    models += "}"
    return ('{"range": ' + json_string(rng) + ', "bucket_seconds": ' + String(step) + ', "start": ' + String(first) + ', "end": '
            + String(first + count * step) + ', "buckets": ' + buckets + ', "models": ' + models + "}")


# requests, bench, pulls, ports ------------------------------------------------------------------------------------

def requests_json(store: Store, limit: Int, model: String) raises -> String:
    var where = String(" WHERE model = ?") if model != "" else String("")
    var args = List[String]()
    if model != "":
        args.append(model)
    args.append(String(limit))
    return store.db.one_text("""SELECT coalesce(json_group_array(json_object('id', id, 'ts', ts, 'app', app, 'model', model, 'route', route,
        'status', status, 'prompt_tokens', prompt_tokens, 'completion_tokens', completion_tokens, 'ttft_ms', ttft_ms, 'duration_ms', duration_ms,
        'estimated', json(CASE WHEN estimated != 0 THEN 'true' ELSE 'false' END))), '[]')
        FROM (SELECT * FROM requests""" + where + " ORDER BY ts DESC, id DESC LIMIT ?)", args)


comptime _RESULT = """json_object('id', id, 'run_id', run_id, 'model', model, 'status', status, 'error', error, 'load_seconds', load_seconds,
    'runs_ok', runs_ok, 'errors', errors, 'decode_tps', decode_tps, 'prefill_tps', prefill_tps, 'ttft_p50_ms', ttft_p50_ms,
    'ttft_p95_ms', ttft_p95_ms, 'duration_ms', duration_ms, 'total_ms', total_ms, 'prompt_tokens', prompt_tokens,
    'completion_tokens', completion_tokens, 'estimated', json(CASE WHEN estimated != 0 THEN 'true' ELSE 'false' END),
    'prompt_estimated', json(CASE WHEN prompt_estimated != 0 THEN 'true' ELSE 'false' END),
    'completion_estimated', json(CASE WHEN completion_estimated != 0 THEN 'true' ELSE 'false' END))"""


def run_sql(where: String) -> String:
    """bench_runs rows as run_dicts (spec §4 bench): results sorted by decode_tps (nulls last), place on the ranked ones."""
    return ("""SELECT coalesce(json_group_array(json_object('id', r.id, 'started_at', r.started_at, 'finished_at', r.finished_at, 'status', r.status,
        'runs', r.runs, 'max_tokens', r.max_tokens, 'prompt_tokens', r.prompt_tokens, 'models', json(r.models),
        'results', (SELECT coalesce(json_group_array(json_patch(""" + _RESULT + """, CASE WHEN decode_tps IS NULL THEN '{}' ELSE json_object('place', rank) END)), '[]')
            FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY decode_tps IS NULL, decode_tps DESC, model) AS rank FROM bench_results WHERE run_id = r.id
                  ORDER BY decode_tps IS NULL, decode_tps DESC, model)))), '[]')
        FROM (SELECT * FROM bench_runs """ + where + ") r")


def bench_json(store: Store, running: Bool = False) raises -> String:
    var latest = store.db.one_text(run_sql("WHERE status IN ('done', 'failed') ORDER BY started_at DESC, id DESC LIMIT 1"))
    var j = Json.parse(latest)
    var one = String("null")
    if j.size(0) > 0:
        one = String(latest[byte = 1 : latest.byte_length() - 1])
    var progress = String("null")
    if running:  # (the run going now: how many of its models are done)
        progress = store.db.one_text("""SELECT json_object('id', r.id, 'models', json_array_length(r.models), 'done', (SELECT COUNT(*) FROM bench_results b WHERE b.run_id = r.id))
            FROM bench_runs r WHERE r.status = 'running' ORDER BY r.id DESC LIMIT 1""")
        if progress == "":
            progress = "null"
    return '{"running": ' + ("true" if running else "false") + ', "progress": ' + progress + ', "latest": ' + one + "}"


def bench_history_json(store: Store, limit: Int) raises -> String:
    return store.db.one_text(run_sql("ORDER BY started_at DESC, id DESC LIMIT " + String(limit)))


comptime CURATED_JSON = '{"qwen2.5-0.5b": "Qwen/Qwen2.5-0.5B-Instruct", "qwen2.5-1.5b": "Qwen/Qwen2.5-1.5B-Instruct", "qwen2.5-3b": "Qwen/Qwen2.5-3B-Instruct", "smollm2-1.7b": "HuggingFaceTB/SmolLM2-1.7B-Instruct", "llama3.2-1b": "meta-llama/Llama-3.2-1B-Instruct", "all-minilm-l6": "sentence-transformers/all-MiniLM-L6-v2"}'
comptime STEPS = ["resolve", "architecture", "download", "verify", "register"]
comptime STEP_LABELS = ["Resolve", "Architecture", "Download", "Verify", "Register"]


def pull_json(store: Store, id: Int) raises -> String:
    """One pull, in the list's shape ("" when there's no such pull)."""
    var all = pulls_json(store, id)
    var j = Json.parse(all)
    var list = j.get(0, "pulls")
    if j.size(list) == 0:
        return ""
    var start = all.find("[") + 1
    var end = all.rfind('], "curated"')
    return String(all[byte = start:end])


def pulls_json(store: Store, only: Int = -1) raises -> String:
    var rows = store.db.one_text("""SELECT coalesce(json_group_array(json_object('id', id, 'ref', ref, 'name', name, 'repo_id', repo_id, 'status', status,
        'step', step, 'message', message, 'hint', hint, 'error_kind', error_kind, 'started_at', started_at, 'finished_at', finished_at,
        'files', json(files), 'details', json(details), 'model', model, 'speed', speed, 'total', total_bytes)), '[]') FROM (SELECT * FROM pulls WHERE ? < 0 OR id = ? ORDER BY id DESC LIMIT 20)""", [String(only), String(only)])
    var j = Json.parse(rows)
    var out = String("[")
    for i in range(j.size(0)):
        var p = j.at(0, i)
        var status = j.text(j.get(p, "status"))
        var step = j.text(j.get(p, "step"))
        var files = j.get(p, "files")
        var total = 0
        var done = 0
        var fl = String("[")
        for k in range(j.size(files)):
            var f = j.at(files, k)
            var size_node = j.get(f, "size")
            var has_size = size_node >= 0 and j.kind(size_node) == J_NUMBER
            var size = j.number(size_node) if has_size else 0
            var d = j.number(j.get(f, "done"))
            total += size
            done += d
            var st = String("done") if has_size and size > 0 and d >= size else (String("now") if d > 0 else String("next"))
            fl += (", " if k > 0 else "") + '{"name": ' + json_string(j.text(j.get(f, "name"))) + ', "size": ' + (String(size) if has_size else "null") + ', "done": ' + String(d) + ', "state": ' + json_string(st) + "}"
        fl += "]"
        var percent = String("null")
        if total > 0:
            percent = "100.0" if status == "done" else num(rnd(Float64(done) * 100 / Float64(total), 1))
        elif done > 0:
            percent = "100.0"
        var details = j.get(p, "details")
        var steps = String("[")
        var at = -1
        for s in range(5):
            if materialize[STEPS]()[s] == step:
                at = s
        for s in range(5):
            var sid = String(materialize[STEPS]()[s])
            var st = String("next")
            if status == "done" or s < at:
                st = "done"
            elif s == at:
                st = "now" if status == "running" else ("cancelled" if status == "cancelled" else "failed")
            steps += (", " if s > 0 else "") + '{"id": ' + json_string(sid) + ', "label": ' + json_string(String(materialize[STEP_LABELS]()[s])) + ', "state": ' + json_string(st) + ', "detail": ' + json_string(j.text(j.get(details, sid))) + "}"
        steps += "]"
        out += (", " if i > 0 else "") + '{"id": ' + String(j.number(j.get(p, "id"))) + ', "ref": ' + json_string(j.text(j.get(p, "ref"))) + ', "name": ' + text_or_null(j, j.get(p, "name"))
        out += ', "repo_id": ' + text_or_null(j, j.get(p, "repo_id")) + ', "status": ' + json_string(status) + ', "step": ' + json_string(step)
        out += ', "message": ' + json_string(j.text(j.get(p, "message"))) + ', "hint": ' + text_or_null(j, j.get(p, "hint")) + ', "error_kind": ' + text_or_null(j, j.get(p, "error_kind"))
        out += ', "started_at": ' + num(j.real(j.get(p, "started_at"))) + ', "finished_at": ' + real_or_null(j, j.get(p, "finished_at"))
        var speed = j.number(j.get(p, "speed")) if status == "running" and step == "download" else 0
        if total == 0:
            total = j.number(j.get(p, "total"))
        var eta = String(Int((total - done) / speed)) if speed > 0 and total > done else String("null")
        out += ', "total_bytes": ' + String(total) + ', "done_bytes": ' + String(done) + ', "percent": ' + percent + ', "speed": ' + String(speed) + ', "eta_seconds": ' + eta
        out += ', "files": ' + fl + ', "steps": ' + steps + ', "model": ' + text_or_null(j, j.get(p, "model")) + "}"
    return '{"pulls": ' + out + '], "curated": ' + CURATED_JSON + ', "fake_hub": false}'


def text_or_null(j: Json, node: Int) -> String:
    if node < 0 or j.kind(node) != J_STRING:
        return "null"
    return json_string(j.text(node))


def real_or_null(j: Json, node: Int) -> String:
    if node < 0 or j.kind(node) != J_NUMBER:
        return "null"
    return num(j.real(node))


def ports_json(store: Store, home: String, only: Int = 0) raises -> String:
    """The last 20 ports (`only`: that one alone, "" when there is no such port), each with the tail of its log and
    what a person needs to carry a failed port on by hand (goal 64 M3): the workspace, the full log, the gate that
    failed and the best attempt kept."""
    var where = " WHERE id = " + String(only) if only > 0 else String("")
    var rows = store.db.one_text("""SELECT coalesce(json_group_array(json_object('id', id, 'ref', ref, 'name', name, 'repo_id', repo_id, 'status', status,
        'stage', stage, 'message', message, 'started_at', started_at, 'finished_at', finished_at, 'max_attempts', max_attempts,
        'stages', json(stages), 'log', ? || '/ports/' || id || '/port.log', 'model', model)), '[]') FROM (SELECT * FROM ports""" + where
        + " ORDER BY id DESC LIMIT 20)", [home])
    var j = Json.parse(rows)
    var out = String("[")
    for i in range(j.size(0)):
        var p = j.at(0, i)
        var log = j.text(j.get(p, "log"))
        var tail = file_tail(log, 16000)
        var lines = tail.split("\n")
        var last = String("")
        var from_line = max(0, len(lines) - 40)
        for k in range(from_line, len(lines)):
            last += ("\n" if k > from_line else "") + String(lines[k])
        var text = rows_item(rows, j, i)
        var id = j.number(j.get(p, "id"))
        var name = j.text(j.get(p, "name"))
        var workspace = home + "/ports/" + workspace_name(name) if name != "" else String("")
        var best = home + "/ports/" + String(id) + "/best"
        # the gate that failed, as the screen shows it: the last failed row, with its attempt and what it said
        var failed = String("null")
        var stages = j.get(p, "stages")
        for k in range(j.size(stages)):
            var s = j.at(stages, k)
            if j.text(j.get(s, "status")) == "failed":
                failed = ('{"name": ' + json_string(j.text(j.get(s, "name"))) + ', "attempt": ' + text_or_number(j, j.get(s, "attempt"))
                          + ', "detail": ' + json_string(j.text(j.get(s, "detail"))) + "}")
        out += (", " if i > 0 else "") + String(text[byte = : text.byte_length() - 1]) + ', "log_tail": ' + json_string(last)
        out += ', "workspace": ' + json_string(workspace) + ', "port_dir": ' + json_string(workspace + "/port/" + package_slug(name) if name != "" else String(""))
        out += ', "failed_stage": ' + failed + ', "best_kept": ' + ("true" if isdir(best) else "false")
        out += ', "best_path": ' + (json_string(best) if isdir(best) else "null") + ', "beta": true}'
    if only > 0:
        return String(out[byte = 1 :]) if j.size(0) > 0 else String("")
    return '{"ports": ' + out + "]}"


def text_or_number(j: Json, node: Int) -> String:
    if node < 0 or j.kind(node) != J_NUMBER:
        return "null"
    return String(j.number(node))


def rows_item(rows: String, j: Json, i: Int) -> String:
    """The i-th object of a JSON array as text (re-serialised from the parsed node)."""
    return serialize(j, j.at(0, i))


def serialize(j: Json, node: Int) -> String:
    var k = j.kind(node)
    if k == J_NULL:
        return "null"
    if k == J_STRING:
        return json_string(j.text(node))
    if k == J_NUMBER:
        return String(j.number(node)) if j.is_whole(node) else num(j.real(node))
    if k == J_ARRAY:
        var out = String("[")
        for i in range(j.size(node)):
            out += (", " if i > 0 else "") + serialize(j, j.at(node, i))
        return out + "]"
    if k == J_OBJECT:
        var out = String("{")
        for i in range(j.size(node)):
            out += (", " if i > 0 else "") + json_string(j.keys[node][i]) + ": " + serialize(j, j.at(node, i))
        return out + "}"
    return "true" if j.flag(node) else "false"
