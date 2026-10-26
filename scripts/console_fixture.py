"""The original MXConsole on recorded replies (goal 33 M0): a small local HTTP server.

It serves the console's own files from MXCONSOLE_DIR (default ~/Projects/mxstudio/mxconsole/console) on the
daemon's paths (/console, /console/<asset>, /console/omxqua/<path>, with the daemon's CSP headers) and answers
/admin/* from docs/goals/33/fixtures (_manifest.json maps "METHOD /path?query" to a reply file, its status, its
content type and any headers the console reads). Anything it can't answer is a 404 and goes on its miss list.

    pixi run python scripts/console_fixture.py [port]       # replay; open http://127.0.0.1:<port>/console

Writes (goal 33 M5): the original's writes are answered as the daemon answers them (admin_api.py) and change what later
reads return: POST /admin/labels/<label>/add|remove {"models": [...]}, POST /admin/labels {"name"}, PATCH and DELETE
/admin/labels/<label>, PUT /admin/labels/order, POST /admin/learn/<name>/open (Jupyter's URLs on jupyter_port, which
serves a small page at /lab/tree/ and /doc/tree/), POST /admin/models/<name>/load|stop. Every /admin request goes on
`log` ({method, target, t: monotonic seconds, admin: its X-Mst-Admin}), every write on `writes` ({method, path, body:
the JSON sent or None, headers}); override(key, body) changes a reply mid-run.

Add a model (goal 33 M6): GET /admin/search?q=<q> answers from the recorded curated results as the daemon's search.py
does (every word in id, repo or architecture; an owner/name query not among them adds a Hugging Face row: its size from
its name, "port" when its name has "novel" in it, too big ones get suggestions). POST /admin/pulls {"ref"} starts a
pull (202) that moves one step per GET /admin/pulls/<id> through PULL_SCRIPT (resolve, architecture, download at
35 % and 70 %, verify, done); done registers the model in GET /admin/models (cold), and its load (0.8 s) makes it ready.
POST /admin/pulls/<id>/cancel, POST /admin/try/chat (a short reply), POST /admin/ports {"ref"} (a port job through
PORT_SCRIPT, one stage per GET /admin/ports/<id>) and POST /admin/ports/<id>/cancel answer likewise. GET /admin/pulls
(the Beacon's) keeps its recorded reply, so the original's shots don't change.

Keys, Gateway, Security, Settings (goal 33 M6): POST /admin/keys {"app"} (201, a new secret, the list shows its
prefix; 409 when the app has one), POST /admin/keys/<app>/rotate, DELETE /admin/keys/<app>; each secret handed out goes
on `issued` (app -> key). POST /admin/litellm/restart (409 while LiteLLM is off), POST /admin/expose and
/admin/expose/stop (/admin/info and /admin/network follow, as expose.start/stop leave them: set_exposed()), POST
/admin/shutdown ({"stopping": true}).

Record mode (used by scripts/console_record.py): Fixtures(upstream="http://127.0.0.1:<daemon port>") forwards
/admin/* to a real daemon instead and keeps the last reply per request; save() writes them as fixtures.
"""

import json
import mimetypes
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "docs" / "goals" / "33" / "fixtures"
MANIFEST = "_manifest.json"
MXCONSOLE_DIR = Path(os.environ.get("MXCONSOLE_DIR", Path.home() / "Projects/mxstudio/mxconsole/console"))
# the daemon's own console headers (mxconsole/gateway.py CONSOLE_HEADERS): the CSP changes what the page may do
CONSOLE_HEADERS = {"Cache-Control": "no-cache", "X-Frame-Options": "DENY",
                   "Content-Security-Policy": "default-src 'self'; frame-src http://127.0.0.1:* http://localhost:*; "
                                              "frame-ancestors 'none'; base-uri 'none'; form-action 'none'; object-src 'none'",
                   "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"}
TYPES = {".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".woff2": "font/woff2",
         ".html": "text/html; charset=utf-8"}
KEPT_HEADERS = ("x-log-truncated",)  # reply headers the console reads (blade-logs.js)
# Add a model's scripted jobs: a pull's step and percent after each poll (the POST's own reply is the first); a port's
# running stage after each poll (len(PORT_STAGES): done); the smoke test's reply.
PULL_SCRIPT = [("resolve", 0), ("architecture", 0), ("download", 35), ("download", 70), ("verify", 100), ("done", 100)]
PORT_STAGES = ["workspace", "skills", "generate", "build", "parity", "register", "serve"]
PORT_SCRIPT = [0, 1, 2, 3, 4, 5, 6, 7]
PORT_LOG = ["sandbox: ready", "claude: reading config.json", "workspace: prepared", "skills: import-model loaded", "generate: wrote model.py",
            "generate: wrote weights adapter", "build: graph built", "build: 0 warnings", "parity: max abs diff 0.0021", "parity: ok",
            "register: registered", "register: done", "serve: answering", "serve: ok", "done", "done"]
TRY_REPLY = "Hello there, nice to meet you!"
LOAD_S, CHAT_S = 0.8, 0.3  # how long a pulled model's load and the smoke test's reply take (a real compile takes minutes)
T0 = 1792964100.0  # the jobs' started times (epoch seconds, a minute after the recording)


def file_name(key, ctype):
    """'GET /admin/series?range=5m' -> 'admin_series@range=5m.json' (POSTs etc. get the method in front)."""
    method, target = key.split(" ", 1)
    path, _, query = target.partition("?")
    name = path.strip("/").replace("/", "_") + (f"@{query}" if query else "")
    name = re.sub(r"[^A-Za-z0-9._=@-]", "_", name)
    if method != "GET":
        name = f"{method}_{name}"
    return name + (".json" if "json" in ctype else ".txt")


class Fixtures:
    """The replies, the miss list, and (record mode) the upstream daemon."""

    def __init__(self, folder=FIXTURES, upstream=None, host=None):
        self.folder, self.upstream, self.host = Path(folder), upstream, host  # host: the Host header sent upstream
        self.misses, self.lock = [], threading.Lock()
        self.log, self.writes = [], []
        self.jupyter_port = 0
        self.replies = {}  # key -> {"status", "type", "headers", "body": bytes}
        self.jobs = {}  # Add a model: pull and port jobs by kind and id: {"kind", "ref", "polls", "cancelled"}
        self.pulled = set()  # models a pull registered (their load makes them ready)
        self.issued = {}  # M6: app -> the last secret handed out for it (shown once)
        self.recorded_at = None
        if upstream is None:
            manifest = json.loads((self.folder / MANIFEST).read_text())
            self.recorded_at = manifest["recorded_at"]
            for key, r in manifest["replies"].items():
                self.replies[key] = {**r, "body": (self.folder / r["file"]).read_bytes()}

    def override(self, key, body, status=200, ctype="application/json"):
        """A reply changed mid-run (a test's new number): later requests for `key` get `body`."""
        with self.lock:
            self.replies[key] = {"status": status, "type": ctype, "headers": {}, "body": body}

    def answer(self, method, target, headers, body):
        key = f"{method} {target}"
        if self.upstream:
            return self._forward(key, method, target, headers, body)
        low = {k.lower(): v for k, v in headers.items()}
        with self.lock:
            self.log.append({"method": method, "target": target, "t": time.monotonic(), "admin": low.get("x-mst-admin")})
        if method != "GET":
            done = self._write(method, target, low, body)
            if done is not None:
                return done
        r = self.replies.get(key)
        if r is None and method == "GET":
            done = self._scripted(target)
            if done is not None:
                return done
        if r is None:
            with self.lock:
                self.misses.append(key)
            return 404, "text/plain", {}, b"not in the fixtures"
        return r["status"], r["type"], r.get("headers", {}), r["body"]

    # -- writes, as the daemon answers them (admin_api.py), changing what later reads return ----------------------
    def _json(self, key):
        return json.loads(self.replies[key]["body"])

    def _put(self, key, value):
        self.replies[key] = {**self.replies[key], "body": (json.dumps(value, indent=1) + "\n").encode()}

    def _relabel(self, fn):
        """fn(models, labels) changes both lists in place; the labels' counts follow."""
        models, labels = self._json("GET /admin/models"), self._json("GET /admin/labels")
        fn(models, labels)
        for i, l in enumerate(labels):
            l["position"], l["count"] = i, sum(1 for m in models if l["name"] in m.get("labels", []))
        self._put("GET /admin/models", models)
        self._put("GET /admin/labels", labels)

    def _write(self, method, target, headers, body):
        path = target.split("?", 1)[0]
        try:
            sent = json.loads(body) if body else None
        except ValueError:
            sent = "not json"
        with self.lock:
            self.writes.append({"method": method, "path": path, "body": sent, "headers": headers})
        ok = lambda v: (200, "application/json", {}, json.dumps(v).encode())
        bad = lambda code, msg: (code, "application/json", {}, json.dumps({"error": {"message": msg, "code": "invalid_request_body"}}).encode())
        m = re.fullmatch(r"/admin/labels/([^/]+)/(add|remove)", path)
        if method == "POST" and m:
            label, action = urllib.parse.unquote(m.group(1)), m.group(2)
            names = (sent or {}).get("models") if isinstance(sent, dict) else None
            if not isinstance(names, list):
                return bad(400, "Send JSON with `models` (a list of model names).")
            def fn(models, labels):
                if action == "add" and label not in [l["name"] for l in labels]:
                    labels.append({"name": label})
                for x in models:
                    have = x.setdefault("labels", [])
                    if x["name"] in names:
                        if action == "add" and label not in have:
                            have.append(label)
                        if action == "remove" and label in have:
                            have.remove(label)
            with self.lock:
                self._relabel(fn)
            return ok({"name": label, "models": names})
        if method == "POST" and path == "/admin/labels":
            name = (sent or {}).get("name") if isinstance(sent, dict) else None
            with self.lock:
                self._relabel(lambda models, labels: labels.append({"name": name}) if name not in [l["name"] for l in labels] else None)
            return ok({"name": name})
        m = re.fullmatch(r"/admin/labels/([^/]+)", path)
        if m and method in ("PATCH", "DELETE") and m.group(1) != "order":
            old, new = urllib.parse.unquote(m.group(1)), (sent or {}).get("name") if isinstance(sent, dict) else None
            def fn(models, labels):
                for x in models:
                    x["labels"] = [new if l == old else l for l in x.get("labels", []) if method == "PATCH" or l != old]
                labels[:] = [{"name": new} if l["name"] == old else l for l in labels if method == "PATCH" or l["name"] != old]
            with self.lock:
                self._relabel(fn)
            return ok({"name": new if method == "PATCH" else old})
        if method == "PUT" and path == "/admin/labels/order":
            names = (sent or {}).get("names", [])
            with self.lock:
                self._relabel(lambda models, labels: labels.sort(key=lambda l: names.index(l["name"]) if l["name"] in names else 99))
            return ok({"names": names})
        m = re.fullmatch(r"/admin/learn/([^/]+)/open", path)
        if method == "POST" and m:
            name = urllib.parse.unquote(m.group(1))
            nb = json.loads(self.replies.get(f"GET /admin/learn/{name}", {"body": b"{}"})["body"])
            return ok({"name": name, "path": nb.get("path", ""), **jupyter_urls(name, self.jupyter_port)})
        m = re.fullmatch(r"/admin/models/([^/]+)/(load|stop)", path)
        if method == "POST" and m and urllib.parse.unquote(m.group(1)) in self.pulled:
            name, state = urllib.parse.unquote(m.group(1)), "ready" if m.group(2) == "load" else "cold"
            if state == "ready":
                time.sleep(LOAD_S)  # (the daemon answers a load once the graph is compiled and the server answers)
            with self.lock:
                models = self._json("GET /admin/models")
                for x in models:
                    if x["name"] == name:
                        x["state"] = state
                self._put("GET /admin/models", models)
            return ok({"name": name, "state": state})
        if method == "POST" and m:
            return ok({"name": urllib.parse.unquote(m.group(1)), "state": "starting" if m.group(2) == "load" else "cold"})
        if method == "POST" and path in ("/admin/pulls", "/admin/ports"):
            kind = path.rsplit("/", 1)[1][:-1]
            ref = (sent or {}).get("ref") if isinstance(sent, dict) else None
            if not isinstance(ref, str) or not ref:
                return bad(400, "Send JSON with `ref` (a model name or a Hugging Face repo id).")
            with self.lock:
                for jid, j in self.jobs.items():
                    if j["kind"] == kind and j["ref"] == ref and not j["cancelled"] and j["polls"] < len(PULL_SCRIPT if kind == "pull" else PORT_SCRIPT) - 1:
                        body = {"error": {"message": f"{ref} is already being pulled.", "code": f"{kind}_in_progress"}, kind: self._job(jid)}
                        return 409, "application/json", {}, json.dumps(body).encode()
                jid = 100 + len(self.jobs)
                self.jobs[jid] = {"kind": kind, "ref": ref, "polls": 0, "cancelled": False}
                return 202, "application/json", {}, json.dumps(self._job(jid)).encode()
        m = re.fullmatch(r"/admin/(pulls|ports)/(\d+)/cancel", path)
        if method == "POST" and m:
            with self.lock:
                j = self.jobs.get(int(m.group(2)))
                if j is None:
                    return bad(404, "No such job.")
                j["cancelled"] = True
                return ok(self._job(int(m.group(2))))
        # -- Keys, Gateway, Security, Settings (M6), as gateway.py and admin_system.py answer ------------------------
        err = lambda code, msg, c: (code, "application/json", {}, json.dumps({"error": {"message": msg, "code": c}}).encode())
        if method == "POST" and path == "/admin/keys":
            app = (sent or {}).get("app") if isinstance(sent, dict) else None
            if not isinstance(app, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", app):
                return bad(400, "Send JSON like {\"app\": \"my-app\"}: letters, digits, '.', '_' or '-'.")
            with self.lock:
                rows = self._json("GET /admin/keys")
                if any(k["app"] == app for k in rows):
                    return err(409, f"There is already a key for `{app}`.", "key_exists")
                key = self._secret(app)
                rows.append({"app": app, "prefix": key[:12], "created_at": self.recorded_at or time.time(), "last_used_at": None,
                             "revoked_at": None, "status": "active"})
                rows.sort(key=lambda k: k["app"])
                self._put("GET /admin/keys", rows)
            return 201, "application/json", {}, json.dumps({"app": app, "key": key}).encode()
        m = re.fullmatch(r"/admin/keys/([^/]+)/rotate", path)
        if method == "POST" and m:
            app = urllib.parse.unquote(m.group(1))
            with self.lock:
                rows = self._json("GET /admin/keys")
                row = next((k for k in rows if k["app"] == app), None)
                if row is None:
                    return err(404, f"There is no key for `{app}`.", "key_not_found")
                key, revived = self._secret(app), row["revoked_at"] is not None
                row.update(prefix=key[:12], revoked_at=None, status="active")
                self._put("GET /admin/keys", rows)
            return ok({"app": app, "key": key, "revived": revived})
        m = re.fullmatch(r"/admin/keys/([^/]+)", path)
        if method == "DELETE" and m:
            app = urllib.parse.unquote(m.group(1))
            with self.lock:
                rows = self._json("GET /admin/keys")
                row = next((k for k in rows if k["app"] == app and k["revoked_at"] is None), None)
                if row is None:
                    return err(404, f"There is no active key for `{app}`.", "key_not_found")
                row.update(revoked_at=self.recorded_at or time.time(), status="revoked")
                self._put("GET /admin/keys", rows)
            return ok({"app": app, "status": "revoked"})
        if method == "POST" and path == "/admin/litellm/restart":
            if not self._json("GET /admin/network")["expose"]["litellm"]:
                return err(409, "LiteLLM isn't running. Start it with `mxc expose`.", "litellm_not_running")
            return ok({"restarted": True})
        if method == "POST" and path in ("/admin/expose", "/admin/expose/stop"):
            on = path == "/admin/expose"
            if on and sent is not None and not isinstance(sent, dict):
                return bad(400, "Send JSON like {\"host\": \"box.local\", \"litellm\": true} (both optional).")
            with self.lock:
                url = self.set_exposed(on)
            return ok({"exposed": True, "lan_endpoint": url, "host": url.split("//")[1].split(":")[0]} if on else {"exposed": False})
        if method == "POST" and path == "/admin/shutdown":
            return ok({"stopping": True})
        if method == "POST" and path == "/admin/try/chat":
            time.sleep(CHAT_S)
            return ok({"id": "chatcmpl-fixture", "object": "chat.completion", "model": (sent or {}).get("model", ""),
                       "choices": [{"index": 0, "message": {"role": "assistant", "content": TRY_REPLY}, "finish_reason": "stop"}]})
        return None

    def _secret(self, app):
        """A new key as keys.create_key makes one (mst- and url-safe characters), kept on `issued`."""
        import secrets
        key = "mst-" + secrets.token_urlsafe(32)[:43]
        self.issued[app] = key
        return key

    def set_exposed(self, on):
        """LAN sharing on or off, as expose.start/stop leave /admin/info and /admin/network; returns the LAN endpoint."""
        net, info = self._json("GET /admin/network"), self._json("GET /admin/info")
        url = f"https://{net['default_host']}:{net['ports']['caddy']}/v1"
        net["expose"] = {"caddy": on, "litellm": on}
        net["exposed"], net["lan_endpoint"], info["lan_endpoint"] = on, url if on else None, url if on else None
        self._put("GET /admin/network", net)
        self._put("GET /admin/info", info)
        return url

    # -- Add a model: search, and pull / port jobs that move one step per poll ------------------------------------
    def _scripted(self, target):
        path, _, query = target.partition("?")
        ok = lambda v: (200, "application/json", {}, json.dumps(v).encode())
        if path == "/admin/search":
            q = urllib.parse.parse_qs(query, keep_blank_values=True).get("q", [""])[0]
            return ok(self._search(q))
        m = re.fullmatch(r"/admin/(pulls|ports)/(\d+)", path)
        if m:
            jid = int(m.group(2))
            with self.lock:
                j = self.jobs.get(jid)
                if j is None or j["kind"] + "s" != m.group(1):
                    return None
                last = len(PULL_SCRIPT if j["kind"] == "pull" else PORT_SCRIPT) - 1
                if not j["cancelled"]:
                    j["polls"] = min(j["polls"] + 1, last)
                job = self._job(jid)
                if job["status"] == "done" and job.get("model"):
                    self._register(job["model"], j["ref"], "ready" if j["kind"] == "port" else "cold")
            return ok(job)
        return None

    def _search(self, q):
        base = json.loads(self.replies["GET /admin/search?q="]["body"])
        mem, pool = base["memory"], base["results"]
        q = q.strip()
        words = q.lower().split()
        hay = lambda r: f"{r['id']} {r['repo_id']} {r['architecture'] or ''}".lower()
        rows = [dict(r) for r in pool if all(w in hay(r) for w in words)]
        rows.sort(key=lambda r: r["id"].lower() != q.lower())
        if re.fullmatch(r"[A-Za-z0-9][\w.-]*/[A-Za-z0-9][\w.-]*", q) and not any(r["repo_id"].lower() == q.lower() for r in rows):
            nums = [float(n) * (1e9 if u in "bB" else 1e6) for n, u in re.findall(r"(?<![\w.])(\d+(?:\.\d+)?)([bBmM])(?![A-Za-z0-9])", q)]
            params = int(max(nums)) if nums else None
            size = None if params is None else round(params * 2 / 1e9, 2)
            est = None if size is None else round(size * 1.2 + 1.0, 1)
            supported = "novel" not in q.lower()
            fit = "port" if not supported else None if est is None else "ok" if est <= mem["free_gb"] * 0.8 else "tight" if est <= mem["free_gb"] else "no"
            rows.insert(0, {"id": q, "repo_id": q, "source": "hf", "architecture": "LlamaForCausalLM" if supported else "NovelForCausalLM",
                            "params": params, "size_gb": size, "est_vram_gb": est, "supported": supported, "fit": fit, "suggestions": []})
        for r in rows:
            if r["fit"] == "no":
                fits = sorted((p for p in pool if p["fit"] == "ok" and p["est_vram_gb"] is not None),
                              key=lambda p: (p["architecture"] != r["architecture"], -p["est_vram_gb"]))
                r["suggestions"] = [{k: p[k] for k in ("id", "repo_id", "architecture", "params", "size_gb", "est_vram_gb")} for p in fits[:3]]
        return {"query": q, "memory": mem, "results": rows, "warnings": []}

    def _job(self, jid):
        """A job as the daemon writes it, at its current step (the lock is held)."""
        j = self.jobs[jid]
        name = j["ref"].split("/")[-1]
        if j["kind"] == "port":
            stages = []
            at = PORT_SCRIPT[j["polls"]]
            for k, stage in enumerate(PORT_STAGES):
                status = "done" if k < at else "running" if k == at else "pending"
                if j["cancelled"] and status == "running":
                    status = "cancelled"
                stages.append({"name": stage, "status": status, "started": T0 + 20 * k if k <= at else None,
                               "ended": T0 + 20 * (k + 1) if k < at else None, "detail": "", "attempt": 1})
            status = "cancelled" if j["cancelled"] else "done" if at >= len(PORT_STAGES) else "running"
            return {"id": jid, "ref": j["ref"], "name": name, "status": status, "stages": stages, "model": name if status == "done" else None,
                    "message": "", "log_tail": "\n".join(PORT_LOG[:2 + 2 * min(at, len(PORT_STAGES))])}
        step = PULL_SCRIPT[j["polls"]]
        status = "cancelled" if j["cancelled"] else "done" if step[0] == "done" else "running"
        order = ["resolve", "architecture", "download", "verify", "register"]
        here = len(order) if step[0] == "done" else order.index(step[0])
        total, done = 1_544_000_000, int(1_544_000_000 * step[1] / 100)
        details = {"resolve": f"{j['ref']} @ 9e7c3a1", "architecture": "Qwen2ForCausalLM is supported by MAX",
                   "download": f"{1 if step[1] < 50 else 2} of 3 files · {done / 1048576:.1f} MB of {total / 1048576:.1f} MB",
                   "verify": "3 files verified", "register": f"registered as {name}"}
        steps = [{"id": o, "label": o.capitalize(), "state": "done" if k < here else "now" if k == here else "next",
                  "detail": details[o] if k <= here else ""} for k, o in enumerate(order)]
        return {"id": jid, "ref": j["ref"], "name": name, "repo_id": j["ref"], "status": status, "step": step[0] if step[0] != "done" else "register",
                "message": "", "hint": None, "error_kind": None, "started_at": T0, "finished_at": T0 + 9 if status == "done" else None,
                "total_bytes": total, "done_bytes": total if status == "done" else done, "percent": 100.0 if status == "done" else float(step[1]),
                "speed": 52_428_800 if step[0] == "download" else 0, "eta_seconds": 20 if step[0] == "download" else None,
                "files": [{"name": "config.json", "size": 700, "done": 700, "state": "done"},
                          {"name": "model.safetensors", "size": total - 7_700_000, "done": max(done - 7_700_000, 0), "state": "now"},
                          {"name": "tokenizer.json", "size": 7_000_000, "done": 0, "state": "next"}],
                "steps": steps, "model": name if status == "done" else None}

    def _register(self, name, ref, state="cold"):
        """A finished job's model joins the list (a pull's cold until it's loaded; a port serves its own), as the daemon does."""
        if name in self.pulled:
            return
        self.pulled.add(name)
        models = self._json("GET /admin/models")
        if not any(x["name"] == name for x in models):
            models.append({"name": name, "repo_id": ref, "revision": "9e7c3a1", "source": "huggingface", "architecture": "Qwen2ForCausalLM",
                           "pinned": False, "keep_alive": 300, "kind": "chat", "size_bytes": 1_544_000_000, "labels": [], "state": state,
                           "port": None, "idle_seconds": None, "starting_seconds": None, "in_flight": 0})
            models.sort(key=lambda x: x["name"])
            self._put("GET /admin/models", models)

    def _forward(self, key, method, target, headers, body):
        req = urllib.request.Request(self.upstream + target, data=body or None, method=method,
                                     headers={**{k: v for k, v in headers.items() if k.lower() in ("x-mst-admin", "content-type")},
                                              **({"Host": self.host} if self.host else {})})
        try:
            with urllib.request.urlopen(req, timeout=30) as res:
                status, rh, data = res.status, res.headers, res.read()
        except urllib.error.HTTPError as e:
            status, rh, data = e.code, e.headers, e.read()
        ctype = rh.get("content-type", "application/octet-stream")
        kept = {h: rh[h] for h in rh.keys() if h.lower() in KEPT_HEADERS}
        with self.lock:
            self.replies[key] = {"status": status, "type": ctype, "headers": kept, "body": data}
        return status, ctype, kept, data

    def save(self, recorded_at):
        """Write every reply as a fixture file plus the manifest (record mode)."""
        self.folder.mkdir(parents=True, exist_ok=True)
        for old in self.folder.iterdir():
            if old.suffix in (".json", ".txt"):
                old.unlink()
        manifest, used = {"recorded_at": recorded_at, "replies": {}}, set()
        for key in sorted(self.replies):
            r = self.replies[key]
            name = file_name(key, r["type"])
            assert name not in used, f"two requests map to {name}"
            used.add(name)
            body = r["body"]
            if "json" in r["type"]:  # pretty and stable, the same values (M2 reads these with json.mojo)
                body = (json.dumps(json.loads(body), indent=1, ensure_ascii=False) + "\n").encode()
            (self.folder / name).write_bytes(body)
            manifest["replies"][key] = {"file": name, "status": r["status"], "type": r["type"], "headers": r["headers"]}
        (self.folder / MANIFEST).write_text(json.dumps(manifest, indent=1) + "\n")


def jupyter_urls(name, port):
    """What Run in Jupyter gets back: Jupyter's lab view and its single-notebook view (jupyter.embed_url), on this machine."""
    url = f"http://127.0.0.1:{port}/lab/tree/{name}.ipynb?token=fixture"
    return {"url": url, "embed_url": url.replace("/lab/tree/", "/doc/tree/", 1)}


def static_file(path):
    """The daemon's console paths -> a file in MXCONSOLE_DIR, or None."""
    if path in ("/console", "/console/"):
        rel = "index.html"
    elif path.startswith("/console/"):
        rel = path[len("/console/"):]
    else:
        return None
    f = (MXCONSOLE_DIR / rel).resolve()
    if MXCONSOLE_DIR.resolve() not in f.parents or not f.is_file():
        return None
    return f


def make_handler(fx):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _reply(self, status, ctype, headers, data):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            for k, v in headers.items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def _any(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            path = self.path.split("?", 1)[0]
            if path.startswith("/admin/"):
                return self._reply(*fx.answer(self.command, self.path, dict(self.headers), body))
            if path == "/favicon.ico":
                return self._reply(204, "text/plain", {}, b"")
            f = static_file(path) if self.command in ("GET", "HEAD") else None
            if f is None:
                with fx.lock:
                    fx.misses.append(f"{self.command} {self.path}")
                return self._reply(404, "text/plain", {}, b"not found")
            ctype = TYPES.get(f.suffix) or mimetypes.guess_type(f.name)[0] or "application/octet-stream"
            self._reply(200, ctype, CONSOLE_HEADERS, f.read_bytes())

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _any

        def log_message(self, *a):
            pass

    return H


class _Jupyter(BaseHTTPRequestHandler):
    """A stand-in for Jupyter's notebook page (what Run in Jupyter frames or opens)."""
    def do_GET(self):
        data = b"<!doctype html><title>Jupyter</title><body style='font:14px sans-serif'>Jupyter (fixture): " + self.path.encode() + b"</body>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


def serve(fx, port=0):
    """Start the server on a thread; returns (server, base URL). server.shutdown() stops it (and the Jupyter stand-in)."""
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(fx))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    jup = ThreadingHTTPServer(("127.0.0.1", 0), _Jupyter)
    jup.daemon_threads = True
    threading.Thread(target=jup.serve_forever, daemon=True).start()
    fx.jupyter_port = jup.server_address[1]
    stop = server.shutdown
    server.shutdown = lambda: (stop(), jup.shutdown())
    return server, f"http://127.0.0.1:{server.server_address[1]}"


if __name__ == "__main__":
    fx = Fixtures()
    server, url = serve(fx, int(sys.argv[1]) if len(sys.argv) > 1 else 8765)
    print(f"the original console on {len(fx.replies)} recorded replies: {url}/console  (Ctrl-C stops)", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        print("misses:", sorted(set(fx.misses)))
