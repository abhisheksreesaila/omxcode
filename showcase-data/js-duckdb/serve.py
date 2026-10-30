"""Build A's local server: the page, the esbuild bundle, DuckDB-WASM's worker and wasm, and the Parquet file.

  pixi run python showcase-data/js-duckdb/serve.py [--port 8738] [--out DIR]

- Sends COOP/COEP so the page is cross-origin isolated (SharedArrayBuffer: DuckDB-WASM's threaded "coi" bundle).
- Serves /data/<file>.parquet from the repo's data/ folder with HTTP Range requests (DuckDB-WASM's HTTP file system
  reads Parquet in ranges) and HEAD.
- POST /out/<name>.json writes the scripted run's answers.json / timings.json into --out; POST /out/done ends a run.
"""
import argparse
import json
import os
import re
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE.parent.parent / "data"
TYPES = {".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".html": "text/html",
         ".css": "text/css", ".json": "application/json", ".parquet": "application/octet-stream", ".png": "image/png"}


class Handler(SimpleHTTPRequestHandler):
    out_dir = HERE / "out"
    done = threading.Event()
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        if os.environ.get("SERVE_LOG"):
            super().log_message(*a)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def resolve(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            return HERE / "index.html"
        if path.startswith("/data/"):
            name = path[len("/data/"):]
            return DATA / name if re.fullmatch(r"orders-\d+M\.parquet", name) else None
        if path == "/steps.json":
            return HERE.parent / "steps.json"
        if path in ("/style.css",):
            return HERE / path[1:]
        if path.startswith("/dist/"):
            p = (HERE / "dist" / path[len("/dist/"):]).resolve()
            return p if p.is_relative_to(HERE / "dist") else None
        return None

    def send_file(self, head):
        p = self.resolve()
        if p is None or not p.is_file():
            self.send_error(404)
            return
        size = p.stat().st_size
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng:
            m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
            if not m:
                self.send_error(416)
                return
            a, b = m.groups()
            if a == "":
                start, end = max(0, size - int(b)), size - 1
            else:
                start, end = int(a), min(size - 1, int(b)) if b else size - 1
            status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", TYPES.get(p.suffix, "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head:
            return
        with open(p, "rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(left, 1 << 22))
                if not chunk:
                    break
                self.wfile.write(chunk)
                left -= len(chunk)

    def do_HEAD(self):
        self.send_file(True)

    def do_GET(self):
        self.send_file(False)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        m = re.fullmatch(r"/out/([a-z0-9_-]+)(\.json)?", self.path)
        if not m:
            self.send_error(404)
            return
        self.out_dir.mkdir(parents=True, exist_ok=True)
        if m.group(1) == "done":
            Handler.done.set()
        else:
            data = json.loads(body)
            (self.out_dir / f"{m.group(1)}.json").write_text(json.dumps(data, indent=1) + "\n")
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()


def serve(port=0, out_dir=None):
    """Starts the server on a thread; returns (server, port)."""
    if out_dir:
        Handler.out_dir = Path(out_dir)
    Handler.done.clear()
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8738)
    ap.add_argument("--out", default=str(HERE / "out"))
    a = ap.parse_args()
    srv, port = serve(a.port, a.out)
    print(f"http://127.0.0.1:{port}/?rows=10M")
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        sys.exit(0)
