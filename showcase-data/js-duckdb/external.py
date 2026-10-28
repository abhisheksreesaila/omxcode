"""Build A, driven from outside: the dashboard opens and waits; an external harness says when to apply each step.

  pixi run python showcase-data/js-duckdb/external.py --rows 100M [--out DIR] [--control-port P] [--headless]

- Starts serve.py's server, opens Chromium (check_a.py's binary and flags: GPU ANGLE on Vulkan) at 1280 x 800 on
  $DISPLAY (--headless: on the repo's Xvfb display instead) with ?scripted=external, and waits for step 0's
  dashboard.
- stdout, one line each: `ready <json>` once step 0 is on screen (the setup, control_port); `shown N <ms> <json>` after
  the frame that shows step N's numbers (ms: the page's change → that frame); `error <text>`; `bye` at the end.
- Commands, from stdin or HTTP (POST http://127.0.0.1:<control_port>/step/N, /quit; the reply is the step's JSON,
  sent after the frame): `step N` applies steps.json's step N through its control (the full state; steps in any
  order), `quit` writes answers.json + timings.json (every step applied, step 0 first) to --out and closes Chromium.
  EOF on stdin is `quit` unless --control-port was given (then only POST /quit ends it).
"""
import argparse
import asyncio
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from concurrent.futures import Future
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "scripts"))
import serve  # noqa: E402
from check_a import CHROMIUM, FLAGS  # noqa: E402


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def say(*parts):
    print(*parts, flush=True)


class CDP:
    """The few Chrome DevTools Protocol calls this needs, over the page's websocket."""

    def __init__(self, ws):
        self.ws, self.n, self.waiting = ws, 0, {}
        self.reader = asyncio.create_task(self.read())

    async def read(self):
        async for raw in self.ws:
            m = json.loads(raw)
            f = self.waiting.pop(m.get("id"), None)
            if f and not f.done():
                f.set_result(m)

    async def evaluate(self, expr):
        self.n += 1
        f = asyncio.get_running_loop().create_future()
        self.waiting[self.n] = f
        await self.ws.send(json.dumps({"id": self.n, "method": "Runtime.evaluate",
                                       "params": {"expression": expr, "awaitPromise": True, "returnByValue": True}}))
        m = await f
        if "error" in m:
            raise RuntimeError(m["error"])
        r = m["result"]
        if "exceptionDetails" in r:
            d = r["exceptionDetails"]
            raise RuntimeError(d.get("exception", {}).get("description") or d.get("text"))
        return r["result"].get("value")


def control_server(port, commands):
    """POST /step/N and /quit: queue the command, reply with its result."""
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            parts = self.path.strip("/").split("/")
            line = " ".join(parts)
            if not (parts[0] == "quit" or (parts[0] == "step" and len(parts) == 2 and parts[1].isdigit())):
                self.send_error(404)
                return
            fut = Future()
            commands(line, fut)
            try:
                body, code = json.dumps(fut.result()).encode(), 200
            except Exception as e:  # noqa: BLE001
                body, code = json.dumps({"error": str(e)}).encode(), 500
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


async def drive(a):
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if a.headless:
        import headless
        headless.ensure()
    srv, port = serve.serve(0, out)
    profile = tempfile.mkdtemp(prefix="chromium-", dir=out)   # not /tmp: RAM-backed here
    dbg = free_port()
    url = f"http://127.0.0.1:{port}/?rows={a.rows}&scripted=external" + (f"&{a.query}" if a.query else "")
    proc = subprocess.Popen([CHROMIUM, *FLAGS, f"--user-data-dir={profile}", f"--remote-debugging-port={dbg}",
                             f"--app={url}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()
    put = lambda line, fut=None: loop.call_soon_threadsafe(queue.put_nowait, (line.strip(), fut))  # noqa: E731
    ctl = None
    try:
        import websockets
        t0 = time.monotonic()
        while True:
            try:
                tabs = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{dbg}/json", timeout=1).read())
                ws_url = next(t["webSocketDebuggerUrl"] for t in tabs if t["type"] == "page")
                break
            except (OSError, StopIteration, ValueError):
                if proc.poll() is not None or time.monotonic() - t0 > 30:
                    raise RuntimeError("Chromium did not start")
                await asyncio.sleep(0.1)
        async with websockets.connect(ws_url, max_size=1 << 28) as ws:
            cdp = CDP(ws)
            while True:   # the page may not have a context yet (still navigating), or replace it once
                try:
                    ready = await cdp.evaluate("""new Promise((res) => { const t = setInterval(() => {
                        if (window.extReady || window.extError) { clearInterval(t);
                          res(window.extError ? { error: window.extError } : window.extReady); } }, 20); })""")
                    if ready is not None:
                        break
                except RuntimeError as e:
                    if "context" not in str(e).lower() or time.monotonic() - t0 > a.timeout:
                        raise
                await asyncio.sleep(0.1)
            if "error" in ready:
                raise RuntimeError(ready["error"])
            if a.control_port is not None:
                ctl = control_server(a.control_port, put)
                ready["control_port"] = ctl.server_address[1]
            say("ready", json.dumps(ready))

            def stdin_reader():
                for line in sys.stdin:
                    if line.strip():
                        put(line)
                if a.control_port is None:
                    put("quit")
            threading.Thread(target=stdin_reader, daemon=True).start()

            while True:
                line, fut = await queue.get()
                try:
                    words = line.split()
                    if words == ["quit"]:
                        res = await cdp.evaluate("window.extResults()")
                        (out / "answers.json").write_text(json.dumps(res["answers"]) + "\n")
                        (out / "timings.json").write_text(json.dumps(res["timings"], indent=1) + "\n")
                        if fut:
                            fut.set_result({"answers": str(out / "answers.json"), "timings": str(out / "timings.json")})
                        break
                    if len(words) != 2 or words[0] != "step" or not words[1].isdigit():
                        raise ValueError(f"unknown command {line!r} (step N | quit)")
                    t = await cdp.evaluate(f"window.extStep({int(words[1])})")
                    say("shown", words[1], f"{t['input_to_pixels_ms']:.2f}", json.dumps(t))
                    if fut:
                        fut.set_result(t)
                except Exception as e:  # noqa: BLE001
                    say("error", str(e).replace("\n", " "))
                    if fut:
                        fut.set_exception(e)
            cdp.reader.cancel()
    finally:
        if ctl:
            ctl.shutdown()
        try:
            os.killpg(proc.pid, signal.SIGTERM)   # only the Chromium this run started (its own session)
            proc.wait(timeout=10)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        srv.shutdown()
        shutil.rmtree(profile, ignore_errors=True)
    say("bye")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", choices=["10M", "100M"], default="100M")
    ap.add_argument("--out", default=str(HERE / "out" / "external"))
    ap.add_argument("--control-port", type=int, help="also take POST /step/N and /quit on this port (0: any free one)")
    ap.add_argument("--headless", action="store_true", help="open Chromium on the repo's Xvfb display, not $DISPLAY")
    ap.add_argument("--timeout", type=float, default=900, help="seconds to wait for step 0's dashboard")
    ap.add_argument("--query", default="", help="extra URL params for app.js (to compare setups)")
    a = ap.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))   # still closes this run's Chromium
    try:
        asyncio.run(drive(a))
    except RuntimeError as e:
        say("error", str(e).replace("\n", " "))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
