"""The original MXConsole on recorded replies (goal 33 M0): a small local HTTP server.

It serves the console's own files from MXCONSOLE_DIR (default ~/Projects/mxstudio/mxconsole/console) on the
daemon's paths (/console, /console/<asset>, /console/omxqua/<path>, with the daemon's CSP headers) and answers
/admin/* from docs/goals/33/fixtures (_manifest.json maps "METHOD /path?query" to a reply file, its status, its
content type and any headers the console reads). Anything it can't answer is a 404 and goes on its miss list.

    pixi run python scripts/console_fixture.py [port]       # replay; open http://127.0.0.1:<port>/console

Record mode (used by scripts/console_record.py): Fixtures(upstream="http://127.0.0.1:<daemon port>") forwards
/admin/* to a real daemon instead and keeps the last reply per request; save() writes them as fixtures.
"""

import json
import mimetypes
import os
import re
import sys
import threading
import urllib.error
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
        self.replies = {}  # key -> {"status", "type", "headers", "body": bytes}
        self.recorded_at = None
        if upstream is None:
            manifest = json.loads((self.folder / MANIFEST).read_text())
            self.recorded_at = manifest["recorded_at"]
            for key, r in manifest["replies"].items():
                self.replies[key] = {**r, "body": (self.folder / r["file"]).read_bytes()}

    def answer(self, method, target, headers, body):
        key = f"{method} {target}"
        if self.upstream:
            return self._forward(key, method, target, headers, body)
        r = self.replies.get(key)
        if r is None:
            with self.lock:
                self.misses.append(key)
            return 404, "text/plain", {}, b"not in the fixtures"
        return r["status"], r["type"], r.get("headers", {}), r["body"]

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


def serve(fx, port=0):
    """Start the server on a thread; returns (server, base URL). server.shutdown() stops it."""
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(fx))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


if __name__ == "__main__":
    fx = Fixtures()
    server, url = serve(fx, int(sys.argv[1]) if len(sys.argv) > 1 else 8765)
    print(f"the original console on {len(fx.replies)} recorded replies: {url}/console  (Ctrl-C stops)", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        print("misses:", sorted(set(fx.misses)))
