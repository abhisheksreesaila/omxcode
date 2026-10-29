"""Build A, driven from outside: the dashboard opens and waits; an external harness says when to apply each step.

  pixi run python showcase-data/js-duckdb/external.py --rows 100M [--out DIR] [--control-port 0] [--warm-browser]

The full contract is in README.md. In short:
- Starts serve.py's server and Chromium at 1280 x 800 with ?scripted=external. Chromium's binary and flags come from
  $DATA_BENCH_CHROMIUM and $DATA_BENCH_CHROMIUM_FLAGS (the harness's protocol; shell words) when set, else
  /usr/lib/chromium/chromium with Wayland flags when $WAYLAND_DISPLAY is set, else check_a.py's X11 flags (--headless:
  the repo's Xvfb display, for checks). Nothing here reads $DISPLAY.
- stdout: `browser <json>` (--warm-browser: Chromium is up on about:blank; send `open`), `ready <json>` once step 0
  is on screen (setup, kpi_rect, control_port), `shown N <ms> <json>` after the frame that shows step N, `error <text>`,
  `bye` at the end.
- Commands, from stdin or HTTP (POST http://127.0.0.1:<control_port>/step/N, /open, /quit; the reply is the result's
  JSON): `open`, `step N` (N = 0 … 32: steps.json's state N, applied through its control), `quit` (answers.json +
  timings.json to --out, then close everything this started). EOF on stdin is `quit` unless --control-port was given.
"""
import argparse
import asyncio
import json
import os
import shlex
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

CHROMIUM = "/usr/lib/chromium/chromium"
# The protocol's flags (docs/goals/38/README.md): Chromium native on Wayland, GPU through ANGLE on Vulkan.
WAYLAND_FLAGS = ["--ozone-platform=wayland", "--enable-features=Vulkan", "--use-angle=vulkan", "--ignore-gpu-blocklist"]
# What every launch adds, whatever the flags: a private profile, the window size, no first-run UI, no throttling.
BASE_FLAGS = ["--no-first-run", "--no-default-browser-check", "--password-store=basic", "--disable-extensions",
              "--window-size=1280,800", "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
              "--disable-backgrounding-occluded-windows"]


def chromium_command(headless):
    """(binary, flags): the harness's when given, else Wayland's or (on Xvfb) check_a.py's X11 set."""
    binary = os.environ.get("DATA_BENCH_CHROMIUM") or CHROMIUM
    if os.environ.get("DATA_BENCH_CHROMIUM_FLAGS"):
        flags = shlex.split(os.environ["DATA_BENCH_CHROMIUM_FLAGS"])
    elif headless or not os.environ.get("WAYLAND_DISPLAY"):
        from check_a import FLAGS
        flags = FLAGS
    else:
        flags = WAYLAND_FLAGS
    flags = [f for f in flags if f != "--app" and not f.startswith("--app=")]   # we add --app=<url> ourselves
    return binary, flags + [f for f in BASE_FLAGS if f.split("=")[0] not in {x.split("=")[0] for x in flags}]


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
        try:
            async for raw in self.ws:
                m = json.loads(raw)
                f = self.waiting.pop(m.get("id"), None)
                if f and not f.done():
                    f.set_result(m)
        except Exception:  # noqa: BLE001  (the socket closed: Chromium went away)
            for f in self.waiting.values():
                if not f.done():
                    f.set_exception(RuntimeError("Chromium closed the page"))

    async def call(self, method, params=None):
        self.n += 1
        f = asyncio.get_running_loop().create_future()
        self.waiting[self.n] = f
        await self.ws.send(json.dumps({"id": self.n, "method": method, "params": params or {}}))
        m = await f
        if "error" in m:
            raise RuntimeError(m["error"])
        return m["result"]

    async def evaluate(self, expr):
        r = await self.call("Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True})
        if "exceptionDetails" in r:
            d = r["exceptionDetails"]
            raise RuntimeError(d.get("exception", {}).get("description") or d.get("text"))
        return r["result"].get("value")


def control_server(port, commands):
    """POST /step/N, /kpi, /open and /quit: queue the command, reply with its result."""
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            parts = self.path.strip("/").split("/")
            if not (parts in (["quit"], ["open"], ["kpi"]) or (parts[0] == "step" and len(parts) == 2 and parts[1].isdigit())):
                self.send_error(404)
                return
            fut = Future()
            commands(" ".join(parts), fut)
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


READY = """new Promise((res) => { const t = setInterval(() => {
    if (window.extReady || window.extError) { clearInterval(t);
      res(window.extError ? { error: window.extError } : window.extReady); } }, 20); })"""


def stop_group(proc):
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)   # only the processes this run started (their own session)
        proc.wait(timeout=10)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


# ---------------------------------------------------------------------------------------------------------------------
# Build A's part: its static server, in this process.
# ---------------------------------------------------------------------------------------------------------------------
def start_app(a, out):
    import serve
    srv, port = serve.serve(0, out)
    url = f"http://127.0.0.1:{port}/?rows={a.rows}&scripted=external" + (f"&{a.query}" if a.query else "")
    return url, srv.shutdown


async def drive(a):
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if a.headless:
        import headless
        headless.ensure()
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()
    put = lambda line, fut=None: loop.call_soon_threadsafe(queue.put_nowait, (line.strip(), fut))  # noqa: E731
    ctl = proc = None
    stop_app = None
    profile = tempfile.mkdtemp(prefix="chromium-", dir=out)   # not /tmp: RAM-backed here
    try:
        url = None
        if not a.warm_browser:
            url, stop_app = start_app(a, out)
        binary, flags = chromium_command(a.headless)
        dbg = free_port()
        cmd = [binary, *flags, f"--user-data-dir={profile}", f"--remote-debugging-port={dbg}",
               f"--app={'about:blank' if a.warm_browser else url}"]
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        if a.control_port is not None:
            ctl = control_server(a.control_port, put)

        def stdin_reader():
            for line in sys.stdin:
                if line.strip():
                    put(line)
            if a.control_port is None:
                put("quit")
        threading.Thread(target=stdin_reader, daemon=True).start()

        import websockets
        t0 = time.monotonic()
        while True:
            try:
                tabs = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{dbg}/json", timeout=1).read())
                ws_url = next(t["webSocketDebuggerUrl"] for t in tabs if t["type"] == "page")
                break
            except (OSError, StopIteration, ValueError):
                if proc.poll() is not None or time.monotonic() - t0 > 30:
                    raise RuntimeError(f"Chromium did not start ({shlex.join(cmd)})")
                await asyncio.sleep(0.1)
        async with websockets.connect(ws_url, max_size=1 << 28) as ws:
            cdp = CDP(ws)
            if a.warm_browser:
                say("browser", json.dumps({"pid": proc.pid, "command": cmd,
                                           "control_port": ctl.server_address[1] if ctl else None}))
                while True:   # wait for `open` (a `quit` before it ends the run)
                    line, fut = await queue.get()
                    if line in ("open", "quit"):
                        break
                    say("error", f"{line!r} before open")
                    if fut:
                        fut.set_exception(RuntimeError("send open first"))
                if line == "quit":
                    if fut:
                        fut.set_result({})
                    return
                t0 = time.monotonic()
                url, stop_app = start_app(a, out)   # the app starts now: its cold start, without the browser's
                await cdp.call("Page.navigate", {"url": url})
                opened = fut
            else:
                opened = None
            while True:   # the page may not have a context yet (still navigating), or replace it once
                try:
                    ready = await cdp.evaluate(READY)
                    if ready is not None:
                        break
                except RuntimeError as e:
                    if "context" not in str(e).lower() or time.monotonic() - t0 > a.timeout:
                        raise
                await asyncio.sleep(0.1)
            if "error" in ready:
                raise RuntimeError(ready["error"])
            ready["control_port"] = ctl.server_address[1] if ctl else None
            ready["chromium"] = cmd[:-3] + cmd[-1:]   # without the run's profile and debug port
            say("ready", json.dumps(ready))
            if opened:
                opened.set_result(ready)

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
                    if words == ["kpi"]:   # the KPI row's rect now (after the harness resized the window)
                        k = await cdp.evaluate("window.extKpi()")
                        say("kpi", json.dumps(k))
                        if fut:
                            fut.set_result(k)
                        continue
                    if len(words) != 2 or words[0] != "step" or not words[1].isdigit():
                        raise ValueError(f"unknown command {line!r} (step N | kpi | quit)")
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
        stop_group(proc)
        if stop_app:
            stop_app()
        shutil.rmtree(profile, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", choices=["10M", "100M"], default="100M")
    ap.add_argument("--out", default=str(HERE / "out" / "external"))
    ap.add_argument("--control-port", type=int, help="also take POST /step/N, /open, /quit on this port (0: any)")
    ap.add_argument("--warm-browser", action="store_true", help="start Chromium on about:blank; open the page on `open`")
    ap.add_argument("--headless", action="store_true", help="Chromium on the repo's Xvfb display (checks), X11 flags")
    ap.add_argument("--timeout", type=float, default=900, help="seconds to wait for step 0's dashboard")
    ap.add_argument("--query", default="", help="extra URL params for app.js (to compare setups)")
    a = ap.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))   # still closes what this run started
    try:
        asyncio.run(drive(a))
    except RuntimeError as e:
        say("error", str(e).replace("\n", " "))
        say("bye")
        return 1
    say("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
