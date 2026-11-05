# consoled's routes: the admin API (the console's screens) and the /v1 gateway. Replies follow the Python daemon's
# (mxstudio mxconsole, docs/goals/50/admin-api-spec.md), field for field; the store's replies are built by SQLite itself
# (json_object / json_group_array), so numbers and nulls come out as they are stored.

from std.os import getenv
from std.sys import exit
from mojoui.serve import Service, Req, Reply, Pipe, proxy
from mojoui.http import Request
from mojoui.process import file_tail
from std.os.path import exists, getsize
from mojoui.sqlite import Database
from mojoui.json import Json, json_string, J_ARRAY, J_STRING
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
from learn import notebook_json
from meter import meter


@fieldwise_init
struct Open(Copyable, Movable):
    """A proxied /v1 request still streaming: logged when its pipe closes."""
    var pipe: Int
    var app: String
    var model: String
    var route: String


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
    return Reply.json('{"error": {"message": ' + json_string(message) + ', "type": ' + json_string(kind)
                      + ', "param": null, "code": ' + json_string(code) + "}}", status)


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
    var stopping: Bool

    def __init__(out self, var cfg: Config) raises:
        self.store = Store(cfg.home + "/mst.db")
        self.sup = Supervisor(cfg.home, cfg.max_cmd, cfg.idle_seconds)
        self.sizes = model_sizes(self.store)
        self.open = List[Open]()
        self.stopping = False
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
        self.sup.sweep()
        if self.stopping:
            for i in range(len(self.sup.children)):
                _ = self.sup.children[i].proc.stop(10_000)
            self.sup.children.clear()
            exit(0)

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
            return Reply.json(info_json(self.store, self.cfg.port, req.header("host"), self.uptime()))
        if req.matches("GET", "/admin/system"):
            return Reply.json(system_json(self.store, self.sup, self.cfg.home, self.cfg.port, self.uptime()))
        if req.matches("GET", "/admin/models"):
            return Reply.json(models_json(self.store, self.sup, self.sizes))
        if req.matches("GET", "/admin/status"):
            return Reply.json(models_json(self.store, self.sup, self.sizes))
        if req.matches("GET", "/admin/gateway"):
            return Reply.json(gateway_json(self.store, self.counters_since, self.unknown_routes, self.admin_refused))
        if req.matches("GET", "/admin/network"):
            return Reply.json(network_json(self.store, self.sup, self.cfg.port))
        if req.matches("GET", "/admin/metrics") or req.matches("GET", "/admin/series"):
            var range = req.arg("range", "5m" if req.path.endswith("metrics") else "1h")
            if window_of(range) < 0:
                return error(400, "range must be one of 5m, 1h, 24h, 7d", "invalid_range")
            return Reply.json(metrics_json(self.store, range) if req.path.endswith("metrics") else series_json(self.store, range))
        if req.matches("GET", "/admin/requests"):
            return Reply.json(requests_json(self.store, clamp(req.arg("limit"), 50, 1, 500), req.arg("model")))
        if req.matches("GET", "/admin/bench"):
            return Reply.json(bench_json(self.store))
        if req.matches("GET", "/admin/bench/history"):
            return Reply.json(bench_history_json(self.store, clamp(req.arg("limit"), 20, 1, 100)))
        if req.matches("GET", "/admin/pulls"):
            return Reply.json(pulls_json(self.store))
        if req.matches("GET", "/admin/ports"):
            return Reply.json(ports_json(self.store, self.cfg.home))
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
                return error(404, "The model `" + req.param("name") + "` is not registered. Run `mxc pull " + req.param("name") + "`.", "model_not_found")
            var i = self.sup.ensure(m.value())
            return Reply.json('{"name": ' + json_string(req.param("name")) + ', "upstream": ' + json_string(self.sup.children[i].base() + "/v1") + ', "state": ' + json_string(self.sup.state(req.param("name"))) + "}")
        if req.matches("POST", "/admin/models/{name}/stop"):
            if not self.model_ref(req.param("name")):
                return error(404, "The model `" + req.param("name") + "` is not registered.", "model_not_found")
            _ = self.sup.stop(req.param("name"))
            return Reply.json('{"name": ' + json_string(req.param("name")) + ', "state": "cold"}')
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
                return error(409, app.value() + " already has a key. Use --rotate to replace it (the old key stops working).", "key_exists")
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
            return error(401, "Incorrect API key provided. Create one with `mxc keys new <app>`.", "invalid_api_key", "authentication_error")
        if route == "":
            return error(404, "omxconsole does not serve " + req.path + ". Supported: /v1/models, /v1/chat/completions, /v1/completions, /v1/embeddings.", "unknown_route")
        if route == "models":
            self.store.log_request(now, app, "", "models", 200, -1, -1, -1.0, 0.0, False)
            return Reply.json(self.v1_models())
        var model = text_field(req.body, "model")
        if not model:
            self.store.log_request(now, app, "", route, 400, -1, -1, -1.0, 0.0, False)
            return error(400, "Request body must be JSON with a string `model` field.", "invalid_request_body")
        var name = model.value()
        var m = self.model_ref(name)
        if not m:
            self.store.log_request(now, app, name, route, 404, -1, -1, -1.0, 0.0, False)
            return error(404, "The model `" + name + "` is not registered. Run `mxc pull " + name + "`.", "model_not_found")
        var i = self.sup.ensure(m.value())
        var ready = self.sup.check_ready(i)
        self.sup.children[i].in_flight += 1
        self.sup.children[i].proc.touch()
        var ctype = req.header("content-type")
        var up = Request(0, "POST", self.sup.children[i].base() + req.path, req.body).header("Content-Type", ctype if ctype != "" else "application/json")
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
