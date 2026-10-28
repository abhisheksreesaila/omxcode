"""Build A's proof: the DuckDB-WASM dashboard in real (GPU) Chromium on the headless display, scripted per SPEC.

  pixi run python showcase-data/js-duckdb/check_a.py              10M, then 100M; prints "A: ok (10M)" / "A: ok (100M)"
  pixi run python showcase-data/js-duckdb/check_a.py --rows 10M   one size
  pixi run python showcase-data/js-duckdb/check_a.py --bench 10M  JSON: per-step latency, query time, cold start, PSS
  extra: --query "bundle=eh&src=url" (app.js's URL params, to compare setups), --shot out/dashboard-{rows}.png

Each run builds the page (build.sh), serves it (serve.py), opens Chromium at 1280 x 800 with the scripted URL, waits
for answers.json + timings.json, samples the PSS of every Chromium process meanwhile, and closes its own Chromium.
"""
import argparse
import asyncio
import json
import math
import os
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(HERE))
import reference  # noqa: E402
import headless  # noqa: E402
import serve  # noqa: E402

CHROMIUM = "/usr/lib/chromium/chromium"
# Real GPU: ANGLE on Vulkan. NVIDIA's Vulkan driver can't present to Xvfb, so without --disable-vulkan-surface the GPU
# process segfaults in a loop (exit 139) and Chromium ends up with no WebGL and a multi-second first frame.
FLAGS = ["--ozone-platform=x11", "--enable-features=Vulkan", "--use-angle=vulkan", "--ignore-gpu-blocklist",
         "--disable-vulkan-surface", "--disable-gpu-sandbox", "--force-device-scale-factor=1",
         "--no-first-run", "--no-default-browser-check", "--disable-background-timer-throttling",
         "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows", "--window-position=0,0",
         "--window-size=1280,800", "--password-store=basic", "--disable-extensions"]


def tree_pss(root_pid):
    """PSS (bytes) of a process and all its descendants, from /proc."""
    kids = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                ppid = int(open(f"/proc/{d}/stat").read().rsplit(")", 1)[1].split()[1])
                kids.setdefault(ppid, []).append(int(d))
            except OSError:
                pass
    total, todo = 0, [root_pid]
    while todo:
        p = todo.pop()
        todo += kids.get(p, [])
        try:
            for line in open(f"/proc/{p}/smaps_rollup"):
                if line.startswith("Pss:"):
                    total += int(line.split()[1]) * 1024
                    break
        except OSError:
            pass
    return total


async def screenshot(port, path):
    import base64
    import urllib.request
    import websockets
    tabs = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json").read())
    ws_url = next(t["webSocketDebuggerUrl"] for t in tabs if t["type"] == "page")
    async with websockets.connect(ws_url, max_size=1 << 28) as ws:
        await ws.send(json.dumps({"id": 1, "method": "Page.captureScreenshot", "params": {"format": "png"}}))
        while True:
            m = json.loads(await ws.recv())
            if m.get("id") == 1:
                Path(path).write_bytes(base64.b64decode(m["result"]["data"]))
                return


def run(rows, steps, query="", shot=None, timeout=1800):
    """One scripted run; returns (answers, timings, peak_pss, wall_to_first_dashboard_s) or raises with the page error."""
    subprocess.run([str(HERE / "build.sh")], check=True)
    reference.data_file(rows, check_lock=False)
    runs = HERE / "out" / "runs"   # not /tmp: it is a RAM-backed tmpfs here, and the Chromium profile is big
    runs.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix=f"a-{rows}-", dir=runs))
    srv, port = serve.serve(0, out)
    headless.ensure()
    profile = tempfile.mkdtemp(prefix="chromium-", dir=runs)
    url = f"http://127.0.0.1:{port}/?rows={rows}&scripted=1&steps={steps}" + (f"&{query}" if query else "")
    dbg = 9300 + os.getpid() % 500
    cmd = [CHROMIUM, *FLAGS, f"--user-data-dir={profile}", f"--remote-debugging-port={dbg}", f"--app={url}"]
    t0 = time.perf_counter()
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    peak, seen = 0, 0
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))   # an outer timeout still closes this run's Chromium
    try:
        while not serve.Handler.done.is_set():
            if time.perf_counter() - t0 > timeout:
                raise RuntimeError(f"timed out after {timeout} s")
            if proc.poll() is not None:
                raise RuntimeError(f"chromium exited ({proc.returncode})")
            peak = max(peak, tree_pss(proc.pid))
            prog = out / "progress.json"
            if prog.exists() and time.perf_counter() - seen > 15:
                seen = time.perf_counter()
                try:
                    g = json.loads(prog.read_text())
                    print(f"  [{time.perf_counter() - t0:6.0f} s] loaded {g['setup'].get('loaded')}, steps {len(g['steps'])}, "
                          f"last {g['steps'][-1]['input_to_pixels_ms'] if g['steps'] else '-'} ms, PSS {peak / 2**30:.2f} GB", file=sys.stderr)
                except (ValueError, KeyError):
                    pass
            time.sleep(0.25)
        if shot:
            asyncio.run(screenshot(dbg, shot.replace("{rows}", rows)))
    finally:
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
    if (out / "error.json").exists():
        err = json.loads((out / "error.json").read_text())
        raise RuntimeError(f"page error: {err['error']} (setup {err.get('setup')})")
    answers = json.loads((out / "answers.json").read_text())
    timings = json.loads((out / "timings.json").read_text())
    print(f"  answers: {out / 'answers.json'}", file=sys.stderr)
    return answers, timings, peak, out


def stats(xs):
    xs = sorted(xs)
    return {"median": round(statistics.median(xs), 2), "p95": round(xs[math.ceil(0.95 * len(xs)) - 1], 2),
            "worst": round(xs[-1], 2)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", choices=["10M", "100M"])
    ap.add_argument("--bench", choices=["10M", "100M"])
    ap.add_argument("--steps", type=int)
    ap.add_argument("--query", default="")
    ap.add_argument("--shot")
    a = ap.parse_args()
    nsteps = len(reference.states()) - 1
    S = a.steps or nsteps
    if a.bench:
        answers, t, peak, out = run(a.bench, S, a.query, a.shot)
        problems = reference.compare(answers, reference.expected(a.bench), steps=S)
        changes = [s for s in t["steps"] if s["step"] > 0]
        print(json.dumps({
            "build": "A js-duckdb", "rows": a.bench, "steps": len(changes), "setup": t["setup"],
            "input_to_pixels_ms": stats([s["input_to_pixels_ms"] for s in changes]),
            "query_ms": stats([s["query_ms"] for s in changes]),
            "render_ms": stats([s["render_ms"] for s in changes]),
            "cold_start_to_first_dashboard_ms": round(t["setup"]["first_dashboard_ms"], 1),
            "data_load_ms": round(t["setup"]["load_ms"], 1),
            "peak_pss_mb": round(peak / 2**20, 1),
            "correct": not problems, "problems": problems[:10]}, indent=1))
        return 0 if not problems else 1
    ok = True
    for rows in ([a.rows] if a.rows else ["10M", "100M"]):
        try:
            answers, t, peak, out = run(rows, S, a.query, a.shot)
        except RuntimeError as e:
            print(f"A: {rows} did not run: {e}")
            ok = False
            continue
        problems = reference.compare(answers, reference.expected(rows), steps=S)
        if problems:
            ok = False
            print(f"A: FAIL ({rows}): {len(problems)} problems")
            for p in problems[:20]:
                print("  " + p)
        else:
            lat = stats([s["input_to_pixels_ms"] for s in t["steps"] if s["step"] > 0])
            print(f"A: ok ({rows})  [{S} steps; input-to-pixels median {lat['median']} ms, worst {lat['worst']} ms; "
                  f"{t['setup']['bundle']}, {t['setup']['threads']} threads; peak PSS {peak / 2**30:.2f} GB]")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
