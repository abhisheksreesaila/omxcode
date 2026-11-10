# consoled's routes: the admin API (the console's screens) and the /v1 gateway. Replies follow the Python daemon's
# (mxstudio mxconsole, docs/goals/50/admin-api-spec.md), field for field; the store's replies are built by SQLite itself
# (json_object / json_group_array), so numbers and nulls come out as they are stored.

from std.os import getenv, makedirs
from std.sys import exit
from std.time import sleep
from mojoui.serve import Service, Req, Reply, Pipe, proxy
from mojoui.http import Request
from mojoui.process import file_tail
from std.os.path import exists, getsize
from mojoui.sqlite import Database
from mojoui.json import Json, json_string, J_ARRAY, J_STRING, J_BOOL
from mojoui.hash import sha256_hex
from mojoui.clock import now_ns, wall_seconds
from flare.crypto.random import random_bytes
from flare.crypto.hmac import base64url_encode
from store import Store, LabelProblem
from sysinfo import hostname
from supervisor import Supervisor, ModelRef
from views import models_json, model_sizes, info_json, gateway_json, network_json, system_json, metrics_json, series_json
from views import requests_json, bench_json, bench_history_json, pulls_json, ports_json, window_of, num
from search import search_json
from learn import notebook_json, ensure_ipynb
from jupyter import Jupyter
from pulls import Pulls, ref_problem
from mojoui.hf import hub_ref
from ports import Ports, MAX_ATTEMPTS, DEFAULT_ATTEMPTS
from porter import (Porter, read_porter, write_porter, remove_porter, porter_env, porter_json, kind_problem,
                    test_porter, detect_claude, port_preflight)
from expose import Exposing, lan_endpoint, default_host, exposed, hostname_ok, NO_CADDY
from mojoui.companion import parent_gone
from bench import Bench, DEFAULT_RUNS, MAX_RUNS
from mojoui.files import remove_tree
from views import pull_json
from meter import meter


comptime MAX_ADMIN_BODY = 4096  # (admin_port.py's cap: neither a port nor a porter setting is bigger than this)
comptime MAX_WAITING = 4  # (/v1 calls and loads waiting for a model at once; the server has 8 workers)
comptime LOAD_WAIT_MS = 600_000  # (a load answers 503 if its server isn't ready by then: the relay's own wait)


@fieldwise_init
struct Open(Copyable, Movable):
    """A proxied /v1 request still streaming: logged when its pipe closes."""
    var pipe: Int
    var app: String
    var model: String
    var route: String


@fieldwise_init
struct Loading(Copyable, Movable):
    """A POST /admin/models/{name}/load still waiting for its server (gateway.py's admin_load awaits ensure_running):
    tick answers it once the server is ready, failed, or past LOAD_WAIT_MS."""
    var pipe: Int
    var name: String
    var since_ns: Int


@fieldwise_init
struct Config(Copyable, Movable):
    var home: String
    var port: Int
    var admin: String
    var idle_seconds: Int
    var max_cmd: String

    @staticmethod
    def from_env() raises -> Config:
        var home = getenv("MXC_HOME", getenv("HOME") + "/.mxc")
        var port = atol(getenv("MXC_PORT", "11435"))
        var idle = atol(getenv("MXC_IDLE_SECONDS", "0"))
        return Config(home, port, getenv("MXC_ADMIN_KEY", "1"), idle, getenv("MXC_MAX", "max"))


def error(status: Int, message: String, code: String, kind: String = "invalid_request_error") -> Reply:
    """The original's OpenAI-shaped error: {"error": {message, type, param, code}}."""
    return Reply.json(error_json(message, code, kind), status)


def error_json(message: String, code: String, kind: String = "invalid_request_error") -> String:
    return ('{"error": {"message": ' + json_string(message) + ', "type": ' + json_string(kind)
            + ', "param": null, "code": ' + json_string(code) + "}}")


def is_loopback(host: String) -> Bool:
    var colon = host.rfind(":")
    var bare = String(host[byte = : colon]) if colon > 0 and host.find("]") < colon else host.copy()
    var h = String(bare.strip("[]"))
    return h == "127.0.0.1" or h == "localhost" or h == "::1" or h == ""


def strings(body: String, field: String) -> Optional[List[String]]:
    """The JSON body's `field` as a list of strings (None: not an object holding one)."""
    try:
        var j = Json.parse(body)
        var n = j.get(0, field)
        if n < 0 or j.kind(n) != J_ARRAY:
            return None
        var out = List[String]()
        for i in range(j.size(n)):
            var k = j.at(n, i)
            if j.kind(k) != J_STRING:
                return None
            out.append(j.text(k))
        return out^
    except:
        return None


comptime TRY_MAX_TOKENS = 1024  # (gateway.py: "Try it" is for a quick look, not for load)


def messages_json(j: Json, msgs: Int) -> String:
    """A chat's messages again as JSON: each one's role and text content (what "Try it" sends)."""
    var out = String("[")
    for i in range(j.size(msgs)):
        var m = j.at(msgs, i)
        out += (", " if i > 0 else "") + '{"role": ' + json_string(j.text(j.get(m, "role"), "user")) + ', "content": ' + json_string(j.text(j.get(m, "content"))) + "}"
    return out + "]"


def owned_folder(path: String, home: String) -> Bool:
    """True for MXC_HOME/models/<name>: exactly one part under models/, and no "", "." or ".." part anywhere."""
    var mine = home + "/models/"
    if not path.startswith(mine):
        return False
    var rest = String(path[byte = mine.byte_length() :])
    if rest == "" or rest.find("/") >= 0 or rest == "." or rest == "..":
        return False
    for part in home.split("/"):
        if String(part) == "." or String(part) == "..":
            return False
    return True


def is_digits(s: String) -> Bool:
    if s.byte_length() == 0 or s.byte_length() > 18:
        return False
    for b in s.as_bytes():
        if Int(b) < 48 or Int(b) > 57:
            return False
    return True


def text_field(body: String, field: String) -> Optional[String]:
    try:
        var j = Json.parse(body)
        var n = j.get(0, field)
        if n < 0 or j.kind(n) != J_STRING:
            return None
        return j.text(n)
    except:
        return None


def app_name_ok(name: String) -> Bool:
    """keys.py APP_NAME: [A-Za-z0-9._-]{1,64}."""
    if name.byte_length() < 1 or name.byte_length() > 64:
        return False
    for b in name.as_bytes():
        var c = Int(b)
        if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 46 or c == 95 or c == 45):
            return False
    return True


def new_secret() raises -> String:
    """keys.py: "mst-" + secrets.token_urlsafe(32) (32 random bytes, base64url without padding)."""
    var s = base64url_encode(random_bytes(32))
    return "mst-" + String(s.rstrip("="))


struct Daemon(Service):
    var cfg: Config
    var store: Store
    var started: Float64
    var admin_refused: Int
    var unauthorized: Int
    var unknown_routes: Int
    var counters_since: Float64
    var sup: Supervisor
    var sizes: Dict[String, Int]
    var open: List[Open]
    var loading: List[Loading]
    var stopping: Bool
    var pulls: Pulls
    var ports: Ports
    var exposing: Exposing
    var bench: Bench
    var bench_key: String  # the benchmark's own key (app "_bench", bench.py BENCH_APP): in memory only, never stored
    var jupyter: Jupyter
    var notebook_key: String  # Jupyter kernels' key (app "_notebook"): in memory only, so it ends with the daemon

    def __init__(out self, var cfg: Config) raises:
        makedirs(cfg.home, exist_ok=True)  # (a first run: no ~/.mxc yet)
        self.store = Store(cfg.home + "/mst.db")
        self.sup = Supervisor(cfg.home, cfg.max_cmd, cfg.idle_seconds)
        self.sizes = model_sizes(self.store)
        self.open = List[Open]()
        self.loading = List[Loading]()
        self.stopping = False
        self.pulls = Pulls()
        self.ports = Ports()
        self.exposing = Exposing()
        self.bench = Bench()
        self.bench_key = new_secret()
        self.jupyter = Jupyter()
        self.notebook_key = new_secret()
        _ = self.store.db.run("UPDATE bench_runs SET status = 'interrupted', finished_at = ? WHERE status = 'running'", [String(wall_seconds())])
        _ = self.store.db.run("UPDATE pulls SET status = 'failed', message = 'The daemon stopped during this pull; pull again to resume.', finished_at = ? WHERE status = 'running'", [String(wall_seconds())])
        _ = self.store.db.run("UPDATE ports SET status = 'failed', message = 'The daemon stopped during this port; the workspace and log are kept.', finished_at = ? WHERE status = 'running'", [String(wall_seconds())])
        self.cfg = cfg^
        self.started = wall_seconds()
        self.counters_since = self.started
        self.admin_refused = 0
        self.unauthorized = 0
        self.unknown_routes = 0

    def admin_ok(mut self, req: Req) -> Bool:
        """The original's rule (gateway.py admin_allowed): from this machine (Host is loopback, no proxy headers), the
        admin header present (its value: $MXC_ADMIN_KEY, "1" by default), an Origin (if any) that's loopback too."""
        var ok = req.header("x-mst-admin") == self.cfg.admin and is_loopback(req.header("host"))
        ok = ok and req.header("x-forwarded-for") == "" and req.header("forwarded") == ""
        var origin = req.header("origin")
        if origin != "":
            var at = origin.find("://")
            ok = ok and is_loopback(String(origin[byte = at + 3 :]) if at >= 0 else origin)
        if not ok:
            self.admin_refused += 1
        return ok

    def tick(mut self):
        """Every second: log finished /v1 requests, unload idle models (supervisor.py's reaper), exit after shutdown."""
        self.settle()
        if parent_gone() and not self.stopping:  # (the console that started us ended without stopping us: crash, kill)
            print("consoled: the app that started it is gone; stopping", flush=True)
            self.stopping = True
        self.sup.sweep()
        self.answer_loads()
        self.jupyter.answer()
        self.ports.sweep()
        var was = len(self.pulls.running)
        self.pulls.refresh(self.store)
        if len(self.pulls.running) < was:
            try:
                self.sizes = model_sizes(self.store)  # (a pull registered a model, or ended)
            except:
                pass
        if self.stopping:
            self.stop()
            exit(0)

    def stop(mut self):
        """SIGTERM/SIGINT or /admin/shutdown: every max serve child stopped before the daemon goes; a load still waiting
        hears why (503) instead of a dropped connection."""
        self.settle()
        for k in range(len(self.loading)):
            var pipe = Pipe.at(self.loading[k].pipe)
            if not pipe.gone():
                pipe.set_head(503, "application/json")
                pipe.write(error_json("consoled is stopping; `" + self.loading[k].name + "` was not loaded.", "model_unavailable", "server_error"))
            pipe.close()
            pipe.release()
        if len(self.loading) > 0:
            sleep(0.3)  # (their server workers send the 503 before the process exits)
        self.loading = List[Loading]()
        self.ports.cancel_all()  # (a stopping daemon must not leave a porting agent running)
        try:
            _ = self.exposing.stop(self.cfg.home)
        except:
            pass
        var opens = len(self.jupyter.waiting)
        self.jupyter.shutdown()  # (Jupyter stops with the daemon; an open still waiting hears why)
        if opens > 0:
            sleep(0.3)  # (as for loads: their workers send the 503 before the process exits)
        self.sup.stop_all_now()

    def answer(mut self, mut req: Req) -> Reply:
        self.settle()
        try:
            if req.path.startswith("/admin/"):
                if not self.admin_ok(req):
                    return Reply.text("admin is only served to this machine", 403)
                return self.admin(req)
            if req.path.startswith("/v1/") or req.path == "/v1":
                return self.gateway(req)
            if req.matches("GET", "/health"):
                return Reply.json('{"ok": true}')
            if req.matches("GET", "/auth/check"):
                # Caddy's forward_auth asks before it proxies a LAN request (goal 64 M4; gateway.py's auth_check):
                # a valid app key answers 200 with the app's name, anything else 401, and the refusal is counted
                # with the rest, since the client never reaches a /v1 route.
                var now = wall_seconds()
                var who = self.key_app(req, now)
                if who == "":
                    self.store.log_request(now, "", "", "auth_check", 401, -1, -1, -1.0, 0.0, False)
                    return Reply.empty(401)
                return Reply.empty(200).header("X-Mst-App", who)
            return Reply.not_found()
        except e:
            try:
                self.store.db.rollback()  # (a transaction an error left open; none open: SQLite says so, ignored)
            except:
                pass
            return error(500, String(e), "internal_error", "server_error")

    # admin --------------------------------------------------------------------------------------------------------

    def uptime(self) -> Int:
        return Int(wall_seconds() - self.started + 0.5)

    def model_ref(self, name: String) raises -> Optional[ModelRef]:
        var row = self.store.db.one_text("SELECT json_array(name, repo_id, revision, coalesce(weights_path, ''), coalesce(custom_arch_path, ''), keep_alive, pinned) FROM models WHERE name = ?", [name])
        if row == "":
            return None
        var j = Json.parse(row)
        var keep = j.number(j.at(0, 5))
        if j.number(j.at(0, 6)) != 0:
            keep = 0  # (pinned: never unloaded)
        return ModelRef(j.text(j.at(0, 0)), j.text(j.at(0, 1)), j.text(j.at(0, 2)), j.text(j.at(0, 3)), j.text(j.at(0, 4)), keep)

    def admin(mut self, mut req: Req) raises -> Reply:
        if req.matches("GET", "/admin/info"):
            return Reply.json(info_json(self.store, self.cfg.port, req.header("host"), self.uptime(), self.cfg.max_cmd, lan_endpoint(self.cfg.home)))
        if req.matches("GET", "/admin/system"):
            return Reply.json(system_json(self.store, self.sup, self.cfg.home, self.cfg.port, self.uptime(), lan_endpoint(self.cfg.home)))
        if req.matches("GET", "/admin/models"):
            return Reply.json(models_json(self.store, self.sup, self.sizes))
        if req.matches("GET", "/admin/status"):
            return Reply.json(models_json(self.store, self.sup, self.sizes))
        if req.matches("GET", "/admin/gateway"):
            return Reply.json(gateway_json(self.store, self.counters_since, self.unknown_routes, self.admin_refused, lan_endpoint(self.cfg.home)))
        if req.matches("GET", "/admin/network"):
            return Reply.json(network_json(self.store, self.sup, self.cfg.port, lan_endpoint(self.cfg.home)))
        if req.matches("GET", "/admin/metrics") or req.matches("GET", "/admin/series"):
            var range = req.arg("range", "5m" if req.path.endswith("metrics") else "1h")
            if window_of(range) < 0:
                return error(400, "range must be one of 5m, 1h, 24h, 7d", "invalid_range")
            return Reply.json(metrics_json(self.store, range) if req.path.endswith("metrics") else series_json(self.store, range))
        if req.matches("GET", "/admin/requests"):
            return Reply.json(requests_json(self.store, clamp(req.arg("limit"), 50, 1, 500), req.arg("model")))
        if req.matches("GET", "/admin/bench"):
            return Reply.json(bench_json(self.store, self.bench.running()))
        if req.matches("POST", "/admin/bench"):
            if self.bench.running():
                return error(409, "A benchmark is already running; wait for it to finish.", "bench_running")
            var runs = DEFAULT_RUNS
            var names = List[String]()
            try:
                var j = Json.parse(req.body if req.body.byte_length() > 0 else "{}")
                var r = j.get(0, "runs")
                if r >= 0:
                    if not j.is_whole(r) or j.number(r) < 1 or j.number(r) > MAX_RUNS:
                        return error(400, "`runs` is a whole number from 1 to " + String(MAX_RUNS) + ".", "invalid_runs")
                    runs = j.number(r)
                var ms = j.get(0, "models")
                for k in range(j.size(ms)):
                    names.append(j.text(j.at(ms, k)))
            except:
                return error(400, "Send JSON: {\"models\": [names], \"runs\": 5} (both optional).", "invalid_request_body")
            if len(names) == 0:  # (none named: every chat model)
                var rows = Json.parse(self.store.db.one_text("SELECT coalesce(json_group_array(name), '[]') FROM (SELECT name FROM models WHERE kind != 'embedding' ORDER BY name)"))
                for k in range(rows.size(0)):
                    names.append(rows.text(rows.at(0, k)))
            for n in names:
                if not self.model_ref(n):
                    return error(404, "The model `" + n + "` is not registered.", "model_not_found")
            if len(names) == 0:
                return error(400, "No chat models to benchmark: pull one first.", "no_models")
            var id = self.bench.start(self.store, names^, runs, self.cfg.port, self.bench_key, self.cfg.home)
            return Reply.json('{"id": ' + String(id) + ', "running": true}', 202)
        if req.matches("GET", "/admin/bench/history"):
            return Reply.json(bench_history_json(self.store, clamp(req.arg("limit"), 20, 1, 100)))
        if req.matches("GET", "/admin/pulls"):
            self.pulls.refresh(self.store)
            return Reply.json(pulls_json(self.store))
        if req.matches("POST", "/admin/pulls"):
            var asked = text_field(req.body, "ref")
            if not asked:
                return error(400, "Send {\"ref\": \"owner/name\"} (a curated name or a Hugging Face repo).", "invalid_ref")
            var why = ref_problem(asked.value())
            if why != "":
                return error(400, why, "invalid_ref")
            var name = text_field(req.body, "name")
            var id = self.pulls.start(self.store, hub_ref(asked.value()), name.value() if name else String(""), self.cfg.home, self.cfg.max_cmd, self.sup.child_env())
            return Reply.json(pull_json(self.store, id), 202)
        if req.matches("GET", "/admin/pulls/{id}"):
            self.pulls.refresh(self.store)
            var view = pull_json(self.store, Int(atol(req.param("id")))) if is_digits(req.param("id")) else String("")
            if view == "":
                return error(404, "No pull " + req.param("id") + ".", "pull_not_found")
            return Reply.json(view)
        if req.matches("POST", "/admin/pulls/{id}/cancel"):
            if not is_digits(req.param("id")):
                return error(404, "No pull " + req.param("id") + ".", "pull_not_found")
            var id = Int(atol(req.param("id")))
            if not self.pulls.cancel(id):
                var view = pull_json(self.store, id)
                return error(404, "No pull " + req.param("id") + ".", "pull_not_found") if view == "" else Reply.json(view)
            return Reply.json(pull_json(self.store, id), 202)
        if req.matches("DELETE", "/admin/models/{name}"):
            var m = self.model_ref(req.param("name"))
            if not m:
                return error(404, "The model `" + req.param("name") + "` is not registered.", "model_not_found")
            if self.store.db.one_text("SELECT 1 FROM pulls WHERE status = 'running' AND (name = ? OR model = ?) LIMIT 1", [req.param("name"), req.param("name")]) == "1":
                return error(409, "`" + req.param("name") + "` is being pulled; cancel the pull first.", "pull_running")
            _ = self.sup.stop(req.param("name"))
            var path = m.value().weights_path
            self.store.db.begin()
            _ = self.store.db.run("DELETE FROM model_labels WHERE model = ?", [req.param("name")])
            _ = self.store.db.run("DELETE FROM models WHERE name = ?", [req.param("name")])
            self.store.db.commit()
            var removed = False
            # only a folder a pull made (MXC_HOME/models/<one part>), with no "." or ".." part, that no other model uses
            if owned_folder(path, self.cfg.home) and self.store.db.one_text("SELECT 1 FROM models WHERE weights_path = ? LIMIT 1", [path]) == "":
                remove_tree(path)
                removed = True
            self.sizes = model_sizes(self.store)
            return Reply.json('{"name": ' + json_string(req.param("name")) + ', "deleted": true, "files_removed": ' + ("true" if removed else "false") + "}")
        if req.matches("GET", "/admin/ports"):
            return Reply.json(ports_json(self.store, self.cfg.home))
        if req.matches("POST", "/admin/ports"):
            if req.body.byte_length() > MAX_ADMIN_BODY:
                return error(413, "That request is too large for a port.", "request_too_large")
            # admin_port.py's route: {"ref": "owner/repo", "name": …, "max_attempts": 3, "unsandboxed": false}
            var asked = text_field(req.body, "ref")
            if not asked:
                return error(400, 'Send JSON like {"ref": "owner/repo", "max_attempts": 3}.', "invalid_request_body")
            var pname = text_field(req.body, "name")
            var attempts = DEFAULT_ATTEMPTS
            var unsandboxed = False
            try:
                var j = Json.parse(req.body if req.body.byte_length() > 0 else "{}")
                var a = j.get(0, "max_attempts")
                if a >= 0:
                    if not j.is_whole(a):
                        return error(400, "`max_attempts` must be a whole number from 1 to " + String(MAX_ATTEMPTS) + ".", "invalid_request_body")
                    attempts = j.number(a)
                var u = j.get(0, "unsandboxed")
                if u >= 0:
                    if j.kind(u) != J_BOOL:
                        return error(400, "`unsandboxed` must be true or false.", "invalid_request_body")
                    unsandboxed = j.flag(u)
            except:
                return error(400, 'Send JSON like {"ref": "owner/repo", "max_attempts": 3}.', "invalid_request_body")
            # the porting assistant must be set up, and its key must work, before an agent is started (goal 64 M1)
            # Claude Code always writes the port: a key only signs it in, so no `claude` refuses the port, key or not
            var p = read_porter(self.cfg.home)
            var pre = port_preflight(p, detect_claude())
            if pre.code != "":
                return error(400, pre.message, pre.code)
            var tried = test_porter(p)
            if not tried.ok:
                return error(400, "The porting assistant could not be used: " + tried.message, "porter_unusable")
            var started = self.ports.start(self.store, String(asked.value().strip()), pname.value() if pname else String(""),
                                           attempts, unsandboxed, self.cfg.home, self.cfg.max_cmd, self.sup.child_env(),
                                           self.cfg.admin, self.cfg.port, porter_env(p))
            if started.code == "port_in_progress":
                var busy = ports_json(self.store, self.cfg.home, started.busy)
                return Reply.json('{"error": {"message": ' + json_string(started.message)
                                  + ', "type": "invalid_request_error", "param": null, "code": "port_in_progress"}, "port": '
                                  + (busy if busy != "" else "null") + "}", 409)
            if started.code != "":
                return error(400, started.message, started.code)
            return Reply.json(ports_json(self.store, self.cfg.home, started.id), 202)
        if req.matches("GET", "/admin/ports/{id}"):
            var view = ports_json(self.store, self.cfg.home, Int(atol(req.param("id")))) if is_digits(req.param("id")) else String("")
            if view == "":
                return error(404, "There is no port number " + req.param("id") + ".", "port_not_found")
            return Reply.json(view)
        if req.matches("POST", "/admin/ports/{id}/cancel"):
            if not is_digits(req.param("id")):
                return error(404, "There is no port number " + req.param("id") + ".", "port_not_found")
            var pid = Int(atol(req.param("id")))
            var view2 = ports_json(self.store, self.cfg.home, pid)
            if view2 == "":
                return error(404, "There is no port number " + req.param("id") + ".", "port_not_found")
            _ = self.ports.cancel(pid)
            return Reply.json(view2, 202)
        if req.matches("GET", "/admin/porter"):
            return Reply.json(porter_json(self.cfg.home))
        if req.matches("POST", "/admin/porter"):
            if req.body.byte_length() > MAX_ADMIN_BODY:
                return error(413, "That request is too large.", "request_too_large")
            var kind = text_field(req.body, "kind")
            if not kind:
                return error(400, 'Send JSON like {"kind": "claude-code"} or {"kind": "anthropic", "key": "…"}.', "invalid_request_body")
            var base = text_field(req.body, "base_url")
            var key = text_field(req.body, "key")
            var model = text_field(req.body, "model")
            var want = Porter(String(kind.value().strip()), String(base.value().strip()) if base else String(""),
                              String(key.value().strip()) if key else String(""), String(model.value().strip()) if model else String(""))
            var why = kind_problem(want.kind, want.base_url, want.key, want.model)
            if why != "":
                return error(400, why, "invalid_porter")
            var tried2 = test_porter(want)
            if not tried2.ok:
                return error(400, tried2.message, "porter_unusable")
            write_porter(self.cfg.home, want)
            return Reply.json(porter_json(self.cfg.home))
        if req.matches("DELETE", "/admin/porter"):
            var gone = remove_porter(self.cfg.home)
            return Reply.json('{"removed": ' + ("true" if gone else "false") + ", " + String(porter_json(self.cfg.home)[byte = 1 :]))
        if req.matches("POST", "/admin/expose"):
            var host = text_field(req.body, "host")
            var want_host = String(host.value().strip()) if host else default_host()
            if not hostname_ok(want_host):
                return error(400, 'Send JSON like {"host": "box.local"} (optional).', "invalid_host")
            var problem = String("")
            try:
                problem = self.exposing.start(self.cfg.home, want_host)
            except e:
                return error(500, String(e), "expose_failed", "server_error")
            if problem != "":
                return error(500, problem, "expose_failed", "server_error")
            return Reply.json('{"exposed": true, "lan_endpoint": ' + json_string(lan_endpoint(self.cfg.home)) + ', "host": '
                              + json_string(want_host) + ', "beta": true}')
        if req.matches("POST", "/admin/expose/stop"):
            _ = self.exposing.stop(self.cfg.home)
            return Reply.json('{"exposed": false}')
        if req.matches("GET", "/admin/search"):
            if req.arg("q").byte_length() > 200:
                return error(400, "The search text is too long.", "invalid_query")
            return Reply.json(search_json(req.arg("q"), self.cfg.home))
        if req.matches("GET", "/admin/learn/{name}"):
            var m = self.model_ref(req.param("name"))
            if not m:
                return error(404, "The model `" + req.param("name") + "` is not registered.", "model_not_found")
            ref r = m.value()
            return Reply.json(notebook_json(r.name, r.repo_id, r.revision, r.weights_path, self.cfg.home, self.cfg.port))
        if req.matches("POST", "/admin/learn/{name}/open"):
            var m = self.model_ref(req.param("name"))
            if not m:
                return error(404, "The model `" + req.param("name") + "` is not registered.", "model_not_found")
            ref r = m.value()
            if r.name.find("/") >= 0 or r.name.startswith("."):
                return error(400, "`" + r.name + "` can't be a notebook's file name.", "invalid_name")
            var file = ensure_ipynb(r.name, r.repo_id, r.revision, r.weights_path, self.cfg.home, self.cfg.port)
            var root = self.cfg.home + "/notebooks"
            var why = self.jupyter.start(root, self.cfg.home, self.cfg.port, self.notebook_key)
            if why != "":
                return error(424, why, "jupyter_missing")
            if self.jupyter.check():
                return Reply.json(self.jupyter.reply(file, root + "/" + file))
            # jupyter.py waited for the port before answering; tick answers this one (a first pixi exec downloads)
            var pipe = self.jupyter.wait(file)
            var reply = Reply.stream(pipe, "application/json", wait_head_ms=300_000)
            pipe.release()
            return reply^
        if req.matches("GET", "/admin/models/{name}/log"):
            if not self.model_ref(req.param("name")):
                return error(404, "The model `" + req.param("name") + "` is not registered.", "model_not_found")
            var path = self.sup.log_path(req.param("name"))
            var big = exists(path) and getsize(path) > 8000
            return Reply.text(file_tail(path, 8000)).header("X-Log-Truncated", "1" if big else "0")
        if req.matches("GET", "/admin/{source}/log"):
            var src = req.param("source")
            if src == "litellm":
                return Reply.text("")  # (LiteLLM was removed: off, an empty log; D-4771)
            if src == "daemon":
                return Reply.text(file_tail(self.cfg.home + "/logs/daemon.log", clamp(req.arg("bytes"), 16000, 1, 65536)))
            return Reply.empty(404)
        if req.matches("POST", "/admin/models/{name}/load"):
            var m = self.model_ref(req.param("name"))
            if not m:
                return error(404, "The model `" + req.param("name") + "` is not registered. Add it in omxconsole first.", "model_not_found")
            var at = self.sup.find(req.param("name"))
            if at >= 0 and self.sup.children[at].proc.running() and self.sup.check_ready(at):  # (already running: no wait, whatever else waits)
                self.sup.children[at].proc.touch()  # (a load keeps it loaded longer, as ensure_running did)
                return Reply.json(self.load_body(req.param("name"), at))
            if self.waiting() >= MAX_WAITING:
                return error(503, String(self.waiting()) + " requests are already waiting for a model; try again shortly.", "model_unavailable", "server_error")
            var i = self.sup.ensure(m.value())
            if self.sup.check_ready(i):
                return Reply.json(self.load_body(req.param("name"), i))
            # gateway.py's admin_load answers once the model runs (or failed to start), never while it starts: the
            # console's Add flow reads "loaded" as ready (D-5539). tick answers it; the reply waits on a server worker.
            var pipe = Pipe()
            self.loading.append(Loading(pipe.share().addr, req.param("name"), Int(now_ns())))
            var reply = Reply.stream(pipe, "application/json", wait_head_ms=LOAD_WAIT_MS + 30_000)
            pipe.release()
            return reply^
        if req.matches("POST", "/admin/models/{name}/stop"):
            if not self.model_ref(req.param("name")):
                return error(404, "The model `" + req.param("name") + "` is not registered.", "model_not_found")
            _ = self.sup.stop(req.param("name"))
            return Reply.json('{"name": ' + json_string(req.param("name")) + ', "state": "cold"}')
        if req.matches("POST", "/admin/try/chat"):
            # gateway.py admin_try_chat: one chat as the console (no app key), max_tokens capped, one completion
            try:
                var j = Json.parse(req.body)
                var msgs = j.get(0, "messages")
                var mt = j.get(0, "max_tokens")
                if j.kind(j.get(0, "model")) != J_STRING or j.kind(msgs) != J_ARRAY or j.size(msgs) == 0 or (mt >= 0 and (not j.is_whole(mt) or j.number(mt) <= 0)):
                    raise Error("shape")
                var cap = min(j.number(mt) if mt >= 0 else TRY_MAX_TOKENS, TRY_MAX_TOKENS)
                var stream = j.flag(j.get(0, "stream"))
                var body = '{"model": ' + json_string(j.text(j.get(0, "model"))) + ', "messages": ' + messages_json(j, msgs) + ', "max_tokens": ' + String(cap) + ', "n": 1' + (', "stream": true' if stream else "") + "}"
                return self.relay("console", "chat", "/v1/chat/completions", body, "application/json", wall_seconds())
            except:
                return error(400, "Send JSON with `model`, a non-empty `messages` list and optionally `max_tokens` (a positive integer, capped at " + String(TRY_MAX_TOKENS) + ") and `stream`.", "invalid_request_body")
        if req.matches("POST", "/admin/try/complete"):
            # the same for a plain completion (no chat template): a ported base model's smoke test (gpt2 has no
            # chat template, so /admin/try/chat fails it with MAX's "Value error" though it serves; D-6418)
            try:
                var j = Json.parse(req.body)
                var mt = j.get(0, "max_tokens")
                if j.kind(j.get(0, "model")) != J_STRING or j.kind(j.get(0, "prompt")) != J_STRING or (mt >= 0 and (not j.is_whole(mt) or j.number(mt) <= 0)):
                    raise Error("shape")
                var cap = min(j.number(mt) if mt >= 0 else TRY_MAX_TOKENS, TRY_MAX_TOKENS)
                var body = ('{"model": ' + json_string(j.text(j.get(0, "model"))) + ', "prompt": ' + json_string(j.text(j.get(0, "prompt")))
                            + ', "max_tokens": ' + String(cap) + ', "n": 1}')
                return self.relay("console", "completions", "/v1/completions", body, "application/json", wall_seconds())
            except:
                return error(400, "Send JSON with `model`, a `prompt` and optionally `max_tokens` (a positive integer, capped at " + String(TRY_MAX_TOKENS) + ").", "invalid_request_body")
        if req.matches("POST", "/admin/shutdown"):
            self.stopping = True
            return Reply.json('{"stopping": true}')
        if req.matches("GET", "/admin/labels"):
            return Reply.json(self.store.labels_json())
        if req.matches("POST", "/admin/labels"):
            var name = text_field(req.body, "name")
            if not name:
                return error(400, "Send JSON with `name` (the new label).", "invalid_request_body")
            return self.label_reply(self.store.create_label(name.value()), '{"name": ' + json_string(name.value()) + "}")
        if req.matches("PUT", "/admin/labels/order"):
            var names = strings(req.body, "names")
            if not names:
                return error(400, "Send JSON with `names` (every label, in the order you want).", "invalid_request_body")
            return self.label_reply(self.store.reorder_labels(names.value()), '{"names": ' + names_json(names.value()) + "}")
        if req.matches("PATCH", "/admin/labels/{name}"):
            var new = text_field(req.body, "name")
            if not new:
                return error(400, "Send JSON with `name` (the new name).", "invalid_request_body")
            return self.label_reply(self.store.rename_label(req.param("name"), new.value()), '{"name": ' + json_string(new.value()) + "}")
        if req.matches("DELETE", "/admin/labels/{name}"):
            return self.label_reply(self.store.delete_label(req.param("name")), '{"name": ' + json_string(req.param("name")) + "}")
        if req.matches("POST", "/admin/labels/{name}/add") or req.matches("POST", "/admin/labels/{name}/remove"):
            var models = strings(req.body, "models")
            if not models:
                return error(400, "Send JSON with `models` (a list of model names).", "invalid_request_body")
            var label = req.param("name")
            var p = self.store.add_labels(models.value(), label) if req.path.endswith("/add") else self.store.remove_labels(models.value(), label)
            return self.label_reply(p, '{"name": ' + json_string(label) + ', "models": ' + names_json(models.value()) + "}")
        if req.matches("GET", "/admin/keys"):
            return Reply.json(self.store.keys_json())
        if req.matches("POST", "/admin/keys"):
            var app = text_field(req.body, "app")
            if not app or not app_name_ok(app.value()) or app.value().startswith("_"):
                var msg = String("Send JSON like {\"app\": \"my-app\"}: letters, digits, '.', '_' or '-'.")
                if app and app.value().startswith("_"):
                    msg = "app names starting with '_' are reserved for omxconsole"
                return error(400, msg, "invalid_request_body")
            if self.store.key_active(app.value()):
                return error(409, app.value() + " already has a key. Rotate it to replace it (`omxc keys rotate " + app.value() + "`; the old key stops working).", "key_exists")
            var secret = new_secret()
            self.store.put_key(app.value(), secret, sha256_hex(secret), wall_seconds())
            return Reply.json('{"app": ' + json_string(app.value()) + ', "key": ' + json_string(secret) + "}", 201)
        if req.matches("POST", "/admin/keys/{app}/rotate"):
            var app = req.param("app")
            if app.startswith("_") or not self.store.key_exists(app):
                return error(404, "There is no key for `" + app + "`.", "key_not_found")
            var revived = not self.store.key_active(app)
            var secret = new_secret()
            self.store.put_key(app, secret, sha256_hex(secret), wall_seconds())
            return Reply.json('{"app": ' + json_string(app) + ', "key": ' + json_string(secret) + ', "revived": ' + ("true" if revived else "false") + "}")
        if req.matches("DELETE", "/admin/keys/{app}"):
            var app = req.param("app")
            if app.startswith("_") or not self.store.revoke_key(app, wall_seconds()):
                return error(404, "There is no active key for `" + app + "`.", "key_not_found")
            return Reply.json('{"app": ' + json_string(app) + ', "status": "revoked"}')
        return error(404, "no admin route " + req.method + " " + req.path, "not_found")

    def label_reply(self, problem: LabelProblem, ok: String) -> Reply:
        if problem.code == "":
            return Reply.json(ok)
        var status = 404 if problem.code == "label_not_found" or problem.code == "model_not_found" else (409 if problem.code == "label_exists" else 400)
        return error(status, problem.message, problem.code)

    # gateway ------------------------------------------------------------------------------------------------------

    def gateway(mut self, mut req: Req) raises -> Reply:
        var now = wall_seconds()
        var route = String("")
        if req.matches("GET", "/v1/models"):
            route = "models"
        elif req.matches("POST", "/v1/chat/completions"):
            route = "chat"
        elif req.matches("POST", "/v1/completions"):
            route = "completions"
        elif req.matches("POST", "/v1/embeddings"):
            route = "embeddings"
        else:
            self.unknown_routes += 1
        var app = self.key_app(req, now)
        if app == "":
            if route != "":
                self.store.log_request(now, "", "", route, 401, -1, -1, -1.0, 0.0, False)
            return error(401, "Incorrect API key provided. Create one in omxconsole under API keys.", "invalid_api_key", "authentication_error")
        if route == "":
            return error(404, "omxconsole does not serve " + req.path + ". Supported: /v1/models, /v1/chat/completions, /v1/completions, /v1/embeddings.", "unknown_route")
        if route == "models":
            self.store.log_request(now, app, "", "models", 200, -1, -1, -1.0, 0.0, False)
            return Reply.json(self.v1_models())
        return self.relay(app, route, req.path, req.body, req.header("content-type"), now)

    def relay(mut self, app: String, route: String, path: String, body: String, ctype: String, now: Float64) raises -> Reply:
        """A /v1 request for `app` on to its model's max serve (started on demand), streamed back."""
        var model = text_field(body, "model")
        if not model:
            self.store.log_request(now, app, "", route, 400, -1, -1, -1.0, 0.0, False)
            return error(400, "Request body must be JSON with a string `model` field.", "invalid_request_body")
        var name = model.value()
        var m = self.model_ref(name)
        if not m:
            self.store.log_request(now, app, name, route, 404, -1, -1, -1.0, 0.0, False)
            return error(404, "The model `" + name + "` is not registered. Add it in omxconsole first.", "model_not_found")
        var waiting = self.waiting()
        if waiting >= MAX_WAITING:  # (each waits on a server worker for its model's first bytes; keep some for the rest)
            self.store.log_request(now, app, name, route, 503, -1, -1, -1.0, 0.0, False)
            return error(503, String(waiting) + " requests are already waiting for a model to answer; try again shortly.", "model_unavailable", "server_error")
        var i = self.sup.ensure(m.value())
        var ready = self.sup.check_ready(i)
        self.sup.children[i].in_flight += 1
        self.sup.children[i].proc.touch()
        var up = Request(0, "POST", self.sup.children[i].base() + path, body).header("Content-Type", ctype if ctype != "" else "application/json")
        up = up^.header("Accept-Encoding", "identity").timeout(600_000)
        var pipe = Pipe(keep_bytes=1 << 20)
        _ = proxy(up^, pipe, "" if ready else self.sup.children[i].base() + "/health", 0 if ready else 600_000)
        self.open.append(Open(pipe.share().addr, app, name, route))
        var reply = Reply.stream(pipe, "application/json", wait_head_ms=630_000)
        pipe.release()
        return reply^

    def key_app(mut self, req: Req, now: Float64) raises -> String:
        """gateway.py's key check: Authorization: Bearer <key>, its SHA-256 in keys, not revoked; last_used_at kept to the minute."""
        var auth = req.header("authorization")
        var sp = auth.find(" ")
        if sp < 0 or String(auth[byte = : sp]).lower() != "bearer":
            return ""
        var token = String(String(auth[byte = sp + 1 :]).strip())
        if token == "":
            return ""
        if token == self.bench_key:
            return "_bench"
        if token == self.notebook_key:
            return "_notebook"
        return self.store.app_for_key(token, sha256_hex(token), now)

    def v1_models(self) raises -> String:
        var rows = self.store.db.one_text("SELECT coalesce(json_group_array(json_object('name', name, 'repo_id', repo_id, 'pinned', json(CASE WHEN pinned != 0 THEN 'true' ELSE 'false' END), 'keep_alive', keep_alive)), '[]') FROM (SELECT * FROM models ORDER BY name)")
        var j = Json.parse(rows)
        var out = String('{"object": "list", "data": [')
        for k in range(j.size(0)):
            var m = j.at(0, k)
            var n = j.text(j.get(m, "name"))
            var c = self.sup.find(n)
            var state = String("cold")
            if c >= 0:
                state = "ready" if self.sup.children[c].ready else "starting"
            out += (", " if k > 0 else "") + '{"id": ' + json_string(n) + ', "object": "model", "created": 0, "owned_by": "omxconsole", "mxconsole": {"state": ' + json_string(state)
            out += ', "repo_id": ' + json_string(j.text(j.get(m, "repo_id"))) + ', "pinned": ' + ("true" if j.flag(j.get(m, "pinned")) else "false") + ', "keep_alive": ' + String(j.number(j.get(m, "keep_alive"))) + "}}"
        return out + "]}"

    def waiting(self) -> Int:
        """Requests holding a server worker while a model starts: /v1 calls before their first bytes, and loads."""
        var n = len(self.loading)
        for k in range(len(self.open)):
            if Pipe.at(self.open[k].pipe).status() == 0:
                n += 1
        return n

    def load_body(self, name: String, i: Int) -> String:
        return '{"name": ' + json_string(name) + ', "upstream": ' + json_string(self.sup.children[i].base() + "/v1") + ', "state": "ready"}'

    def answer_loads(mut self):
        """The waiting loads whose server is ready (200), gone (503: it failed to start) or too slow (503). A caller that
        left is noticed only then (its worker waits for the head until it's written), as with /v1."""
        var i = 0
        while i < len(self.loading):
            var pipe = Pipe.at(self.loading[i].pipe)
            var name = self.loading[i].name.copy()
            var c = self.sup.find(name)
            var late = Int(now_ns()) - self.loading[i].since_ns > LOAD_WAIT_MS * 1_000_000
            if not pipe.gone() and c >= 0 and not self.sup.check_ready(c) and not late:
                i += 1
                continue
            _ = self.loading.pop(i)
            if not pipe.gone():
                if c >= 0 and self.sup.children[c].ready:
                    pipe.set_head(200, "application/json")
                    pipe.write(self.load_body(name, c))
                else:
                    var why = "not ready after " + String(LOAD_WAIT_MS // 60_000) + " minutes"
                    if c < 0:  # (sweep forgot it: it exited, and said why)
                        why = String(self.sup.last_error) if self.sup.last_error.startswith(name + " exited") else "its server stopped while starting"
                    pipe.set_head(503, "application/json")
                    pipe.write(error_json("Model `" + name + "` failed to start: " + why, "model_unavailable", "server_error"))
            pipe.close()
            pipe.release()

    def settle(mut self):
        """Log the /v1 requests whose streams have ended (gateway.py's request log: ts at the end, tokens from the meter)."""
        var i = 0
        while i < len(self.open):
            var pipe = Pipe.at(self.open[i].pipe)
            if not pipe.closed():
                i += 1
                continue
            var o = self.open.pop(i)
            var ctype = pipe.content_type()
            var streamed = ctype.find("text/event-stream") >= 0
            var m = meter(pipe.kept(), streamed)
            var status = pipe.status() if pipe.status() > 0 else 502
            try:
                self.store.log_request(wall_seconds(), o.app, o.model, o.route, status, m[0], m[1], Float64(pipe.first_ms()) if streamed else -1.0, Float64(pipe.millis()), m[2])
            except:
                pass
            var c = self.sup.find(o.model)
            if c >= 0:
                self.sup.children[c].in_flight = max(0, self.sup.children[c].in_flight - 1)
                self.sup.children[c].proc.touch()
            pipe.release()


def clamp(text: String, default: Int, lo: Int, hi: Int) -> Int:
    try:
        return min(max(atol(text), lo), hi)
    except:
        return default


def names_json(names: List[String]) -> String:
    var out = String("[")
    for i in range(len(names)):
        out += (", " if i > 0 else "") + json_string(names[i])
    return out + "]"
