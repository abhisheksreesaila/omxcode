"""Build B's proof: runs the dashboard's scripted mode (SPEC "Scripted mode") through the real page and the real API,
then compares its answers with reference.py.

  pixi run python showcase-data/py-polars/check_b.py              → "B: ok (10M)", "B: ok (100M)"
  pixi run python showcase-data/py-polars/check_b.py --rows 10M   → one size
  pixi run python showcase-data/py-polars/check_b.py --bench 100M → JSON: per-step latency, server compute time,
                                                                     cold start, peak memory (PSS)
Each run starts the server (server.py, one uvicorn process), opens the page in Chromium on a private Xvfb display
(scripts/headless.py), waits for the page to post answers.json and timings.json (written to out/<rows>/), checks
them, takes a screenshot (screenshot-<rows>.png) and stops both.
"""

import argparse
import json
import math
import os
import socket
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402
import reference  # noqa: E402

CHROMIUM = "/usr/lib/chromium/chromium"
STEPS = len(reference.states()) - 1


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def pss_kb(pid):
    try:
        for line in open(f"/proc/{pid}/smaps_rollup"):
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def processes():
    """{pid: (ppid, comm)} for every process we can read."""
    out = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                stat = open(f"/proc/{d}/stat").read()
                comm = stat[stat.index("(") + 1:stat.rindex(")")]
                ppid = int(stat[stat.rindex(")") + 2:].split()[1])
                out[int(d)] = (ppid, comm)
            except (OSError, ValueError):
                pass
    return out


def descendants(root, procs):
    kids = {}
    for pid, (ppid, _) in procs.items():
        kids.setdefault(ppid, []).append(pid)
    seen, todo = [], [root]
    while todo:
        p = todo.pop()
        seen.append(p)
        todo += kids.get(p, [])
    return seen


class Memory(threading.Thread):
    """Samples the PSS of the server's process tree and of Chromium's processes (our descendants), every 50 ms."""

    def __init__(self, server_pid):
        super().__init__(daemon=True)
        self.server_pid, self.stop_flag = server_pid, False
        self.peak = {"server_mb": 0.0, "browser_mb": 0.0, "total_mb": 0.0}

    def run(self):
        me = os.getpid()
        while not self.stop_flag:
            procs = processes()
            server = descendants(self.server_pid, procs)
            browser = [p for p in descendants(me, procs) if p not in server and procs.get(p, (0, ""))[1].startswith("chrom")]
            s = sum(pss_kb(p) for p in server) / 1024
            b = sum(pss_kb(p) for p in browser) / 1024
            for k, v in (("server_mb", s), ("browser_mb", b), ("total_mb", s + b)):
                self.peak[k] = max(self.peak[k], v)
            time.sleep(0.05)


def run(rows, shot=True):
    """One scripted run. Returns (answers, timings, cold start ms, peak memory)."""
    from playwright.sync_api import sync_playwright
    reference.data_file(rows)                                  # data.lock's bytes, checked before the clock starts
    headless.ensure()
    out = HERE / "out" / rows
    for f in ("answers.json", "timings.json", "done"):
        (out / f).unlink(missing_ok=True)
    port = free_port()
    launched = time.time()
    server = subprocess.Popen([sys.executable, str(HERE / "server.py"), "--rows", rows, "--port", str(port), "--out", str(out)])
    mem = Memory(server.pid)
    mem.start()
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(executable_path=CHROMIUM, headless=False, args=["--ozone-platform=x11"])
            page = browser.new_page(viewport={"width": 1280, "height": 800})
            while True:                                        # the server accepts once the data is in memory
                if server.poll() is not None:
                    raise SystemExit(f"B: server exited ({server.returncode})")
                try:
                    socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                    break
                except OSError:
                    time.sleep(0.02)
            page.goto(f"http://127.0.0.1:{port}/?scripted=1&steps={STEPS}")
            page.wait_for_function("document.title === 'done' || document.title === 'error'", timeout=600_000, polling=50)
            if page.title() == "error":
                raise SystemExit("B: page error: " + page.evaluate("document.body.dataset.error"))
            if shot:
                page.screenshot(path=str(HERE / f"screenshot-{rows}.png"))
            browser.close()
    finally:
        mem.stop_flag = True
        mem.join()
        server.terminate()
        server.wait(timeout=30)
    answers = json.loads((out / "answers.json").read_text())
    timings = json.loads((out / "timings.json").read_text())
    cold_ms = timings["first_dashboard_epoch_ms"] - launched * 1000
    return answers, timings, cold_ms, mem.peak


def stats(xs):
    xs = sorted(xs)
    return {"median": round(statistics.median(xs), 2), "p95": round(xs[math.ceil(0.95 * len(xs)) - 1], 2),
            "worst": round(xs[-1], 2)}


def check(rows):
    answers, timings, cold_ms, peak = run(rows)
    problems = reference.compare(answers, reference.expected(rows), steps=STEPS)
    if problems:
        print(f"B: FAIL ({rows})")
        for p in problems[:20]:
            print("  " + p)
        return False
    steps = timings["steps"][1:]
    print(f"B: ok ({rows})  [{STEPS} steps; input-to-pixels median {stats([s['input_to_pixels_ms'] for s in steps])['median']} ms, "
          f"server compute median {stats([s['server_compute_ms'] for s in steps])['median']} ms; cold start {cold_ms / 1000:.1f} s]")
    return True


def bench(rows):
    answers, timings, cold_ms, peak = run(rows)
    problems = reference.compare(answers, reference.expected(rows), steps=STEPS)
    steps = timings["steps"][1:]                               # step 0 is the opening state, counted in cold start
    print(json.dumps({
        "build": "B: plain JS page + FastAPI/uvicorn (1 process) + Polars, in memory, sorted by day",
        "rows": rows, "steps": len(steps), "correct": not problems,
        "input_to_pixels_ms": stats([s["input_to_pixels_ms"] for s in steps]),
        "server_compute_ms": stats([s["server_compute_ms"] for s in steps]),
        "fetch_ms": stats([s["fetch_ms"] for s in steps]),
        "data_load_ms": round(timings["load_ms"], 1),
        "cold_start_to_first_dashboard_ms": round(cold_ms, 1),
        "peak_pss_mb": {k: round(v, 1) for k, v in peak.items()},
        "per_step_ms": [round(s["input_to_pixels_ms"], 2) for s in steps],
    }, indent=1))
    return not problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", choices=["10M", "100M"])
    ap.add_argument("--bench", choices=["10M", "100M"])
    a = ap.parse_args()
    if a.bench:
        return 0 if bench(a.bench) else 1
    ok = all([check(r) for r in ([a.rows] if a.rows else ["10M", "100M"])])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
