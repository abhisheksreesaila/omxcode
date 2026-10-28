"""Tiny static server for build A (showcase/js-webgpu).

    python serve.py [--port 8036] [--out DIR] [--once]

Serves this folder. The page in scripted mode POSTs:
  /result/<name>  -> written to DIR/<name> (positions.bin, timings.json, error.txt)
  /event/<name>   -> arrival time recorded (first_frame), for cold-start measurement
  /done           -> with --once the server stops
Binds 127.0.0.1 only.
"""
import argparse
import http.server
import json
import threading
import time
from functools import partial
from pathlib import Path

HERE = Path(__file__).resolve().parent
SAFE = {"positions.bin", "timings.json", "error.txt"}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, state, **kw):
        self.state = state
        super().__init__(*a, directory=str(HERE), **kw)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n) if n else b""
        now = time.time()
        path = self.path.split("?")[0]
        st = self.state
        if path.startswith("/result/") and path[8:] in SAFE:
            st["out"].mkdir(parents=True, exist_ok=True)
            (st["out"] / path[8:]).write_bytes(body)
        elif path.startswith("/event/"):
            st["events"][path[7:]] = {"t": now, **(json.loads(body) if body else {})}
        elif path == "/done":
            st["events"]["done"] = {"t": now}
            st["done"].set()
        else:
            self.send_error(404)
            return
        self.send_response(204)
        self.end_headers()

    def log_message(self, *a):
        pass


def start(port=0, out=HERE / "out"):
    """Starts the server in a thread. Returns (server, state); state['done'] is set on /done."""
    state = {"out": Path(out), "events": {}, "done": threading.Event()}
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), partial(Handler, state=state))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, state


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8036)
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--once", action="store_true", help="exit after the page POSTs /done")
    a = ap.parse_args()
    srv, st = start(a.port, a.out)
    print(f"http://127.0.0.1:{srv.server_address[1]}/")
    try:
        if a.once:
            st["done"].wait()
        else:
            threading.Event().wait()
    except KeyboardInterrupt:
        pass
    srv.shutdown()
