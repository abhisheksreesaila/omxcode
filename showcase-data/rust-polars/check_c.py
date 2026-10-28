"""Build C's proof (goal 38 M3): Rust + Polars + egui, scripted at 10M and 100M, compared with reference.py.

Run: pixi run python showcase-data/rust-polars/check_c.py                → "C: ok (10M)", "C: ok (100M)"
     pixi run python showcase-data/rust-polars/check_c.py --rows 10M     (one size)
     pixi run python showcase-data/rust-polars/check_c.py --bench 100M   → JSON: per-step latency, compute, cold start, peak PSS

Builds the release binary (cargo, via pixi), runs it on the repo's headless X display (scripts/headless.py: Xvfb; eframe's
glow backend, so GL comes from Mesa's software rasterizer there), drives steps.json in scripted mode, and checks every
step's answers against DuckDB's (reference.compare). Peak memory is the process's PSS, sampled from
/proc/<pid>/smaps_rollup every 20 ms.
"""

import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "showcase-data"))
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402
import reference  # noqa: E402

BIN = HERE / "target/release/dash"


def build():
    r = subprocess.run(["pixi", "run", "--manifest-path", str(ROOT / "pixi.toml"), "cargo", "build", "--release", "--quiet"],
                       cwd=HERE, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"C: cargo build failed\n{r.stderr[-3000:]}")


def pss_kb(pid):
    try:
        for line in open(f"/proc/{pid}/smaps_rollup"):
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def run(rows, steps=None, shot=None):
    """One scripted run: (answers, timings, peak PSS in MB, wall seconds)."""
    if not headless.ensure() and os.environ.get("MOJOUI_HEADLESS", "1") != "0":
        raise SystemExit("C: no headless display (Xvfb didn't start); not opening windows on the desktop")
    if os.environ.get("MOJOUI_HEADLESS", "1") != "0" and not Path(f"/tmp/.X11-unix/X{os.environ['DISPLAY'][1:]}").exists():
        raise SystemExit(f"C: Xvfb on {os.environ['DISPLAY']} has no socket (a stale /tmp/.tX*-lock?)")
    out = Path(tempfile.mkdtemp(prefix=f"c-{rows}-", dir=HERE / "target"))
    cmd = [str(BIN), "--scripted", "--rows", rows, "--root", str(ROOT), "--out", str(out)]
    if steps is not None:
        cmd += ["--steps", str(steps)]
    if shot:
        cmd += ["--shot", str(shot)]
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    peak = [0]

    def sample():
        while p.poll() is None:
            peak[0] = max(peak[0], pss_kb(p.pid))
            time.sleep(0.02)

    th = threading.Thread(target=sample, daemon=True)
    th.start()
    _, err = p.communicate(timeout=900)
    wall = time.perf_counter() - t0
    th.join()
    if p.returncode:
        raise SystemExit(f"C: the app exited {p.returncode}\n{err[-3000:]}")
    return json.loads((out / "answers.json").read_text()), json.loads((out / "timings.json").read_text()), peak[0] / 1024, wall


def stats(xs):
    xs = sorted(xs)
    return {"median": round(statistics.median(xs), 2), "p95": round(xs[math.ceil(0.95 * len(xs)) - 1], 2),
            "worst": round(xs[-1], 2)}


def bench(rows):
    reference.data_file(rows)
    answers, t, peak, wall = run(rows)
    problems = reference.compare(answers, reference.expected(rows))
    changes = [s for s in t["steps"] if s["step"] > 0]  # the 32 filter changes (step 0 is the opening state)
    print(json.dumps({
        "build": t["build"], "rows": rows, "correct": not problems,
        "input_to_pixels_ms": stats([s["input_to_pixels_ms"] for s in changes]),
        "compute_ms": stats([s["compute_ms"] for s in changes]),
        "cold_start_ms": round(t["cold_start_ms"], 1), "load_ms": round(t["load_ms"], 1),
        "peak_pss_mb": round(peak), "wall_s": round(wall, 1), "threads": t["polars_threads"],
        "per_step": [[s["step"], s["change"], round(s["compute_ms"], 2), round(s["input_to_pixels_ms"], 2)] for s in t["steps"]],
    }, indent=1))


def check(rows, shot=None):
    reference.data_file(rows)
    answers, _, _, _ = run(rows, shot=shot)
    problems = reference.compare(answers, reference.expected(rows))
    if problems:
        print(f"C: FAIL ({rows})")
        for p in problems[:20]:
            print("  " + p)
        return False
    print(f"C: ok ({rows})")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", choices=["10M", "100M"])
    ap.add_argument("--bench", choices=["10M", "100M"])
    ap.add_argument("--shot", type=Path, help="save the last frame as a PNG")
    a = ap.parse_args()
    build()
    if a.bench:
        return bench(a.bench)
    ok = all([check(r, a.shot if r == (a.rows or "10M") else None) for r in ([a.rows] if a.rows else ["10M", "100M"])])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
