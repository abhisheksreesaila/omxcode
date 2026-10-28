"""Build D of goal 38 (omxcode + omxcore): proves examples/dashboard against showcase-data/SPEC.md.

    pixi run python showcase-data/omxcode/check_d.py               # build, scripted at 10M and 100M, compare: "D: ok (10M)", "D: ok (100M)"
    pixi run python showcase-data/omxcode/check_d.py --bench 100M  # JSON: per-step latency, GPU compute, cold start, peak PSS, GPU memory
    pixi run python showcase-data/omxcode/check_d.py --shot 100M OUT.png   # the window once the opening state is drawn
    (--no-build: use the binary already built; --steps S: only steps 1 … S)

The app runs in the real GTK host on the headless display (scripts/headless.py): the data read by MX frame, put on the
GPU once, every step a job off the UI thread, timed from the change to the frame that draws its numbers.
"""
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

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "showcase-data"))
import headless  # noqa: E402
import reference  # noqa: E402

APP = ROOT / "build/dashboard/linux/dashboard"


def build():
    r = subprocess.run(["scripts/build.sh", "dashboard", "linux"], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0 or not APP.exists():
        sys.exit("D: FAIL build\n" + "\n".join(l for l in (r.stdout + r.stderr).splitlines() if "error" in l)[:4000])


def pss_kib(pid):
    try:
        for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def gpu_mib(pid):
    """The process's GPU memory (nvidia-smi), MiB; 0 when it can't say."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 0
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2 and parts[0] == str(pid):
            return int(parts[1])
    return 0


def scripted(rows, out, steps=None, env=None):
    """Runs the app scripted; returns (answers, timings, cold start ms to the first dashboard, peak PSS MiB, peak GPU MiB)."""
    headless.ensure()
    t0 = time.perf_counter()
    cmd = [str(APP), "--scripted", "--rows", rows, "--out", str(out)] + (["--steps", str(steps)] if steps is not None else [])
    p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=dict(os.environ, **(env or {})))
    peak = {"pss": 0, "gpu": 0}
    done = threading.Event()

    def watch():  # PSS every 50 ms, the GPU's memory every 0.5 s
        k = 0
        while not done.is_set():
            peak["pss"] = max(peak["pss"], pss_kib(p.pid))
            if k % 10 == 0:
                peak["gpu"] = max(peak["gpu"], gpu_mib(p.pid))
            k += 1
            time.sleep(0.05)

    w = threading.Thread(target=watch, daemon=True)
    w.start()
    cold = None
    log = []
    for line in p.stdout:
        log.append(line)
        if cold is None and "first dashboard" in line:
            cold = (time.perf_counter() - t0) * 1000
    p.wait()
    done.set()
    w.join()
    if p.returncode != 0 or not (out / "answers.json").exists():
        sys.exit(f"D: FAIL scripted run at {rows} (exit {p.returncode})\n" + "".join(log[-30:]))
    return (json.loads((out / "answers.json").read_text()), json.loads((out / "timings.json").read_text()), cold,
            peak["pss"] / 1024, peak["gpu"])


def pct(xs, q):
    s = sorted(xs)
    return s[max(math.ceil(q * len(s)) - 1, 0)]


def summary(timings):
    steps = [t for t in timings["steps"] if t["step"] > 0]  # (step 0 is the opening state, drawn after the load)
    lat = [t["input_to_pixels_ms"] for t in steps]
    gpu = [t["query_ms"] + t["rows_ms"] for t in steps]
    comp = [t["compute_ms"] for t in steps]
    return lat, gpu, comp


def check(steps=None):
    for rows in ("10M", "100M"):
        reference.data_file(rows)  # (the bytes data.lock pins)
        with tempfile.TemporaryDirectory() as d:
            got, timings, cold, pss, gpu = scripted(rows, Path(d), steps)
        problems = reference.compare(got, reference.expected(rows), steps=steps)
        lat, g, _ = summary(timings)
        print(f"  {rows}: {timings['device']}: {len(got['steps'])} answers; per step input-to-pixels median "
              f"{statistics.median(lat):.1f} ms, worst {max(lat):.1f} ms; GPU compute median {statistics.median(g):.1f} ms; "
              f"cold start {cold:.0f} ms (read {timings['read_ms'] / 1000:.1f} s, upload {timings['upload_ms'] / 1000:.1f} s); "
              f"peak PSS {pss:.0f} MiB, GPU {gpu} MiB")
        if problems:
            sys.exit(f"D: FAIL ({rows}): {len(problems)} problems\n  " + "\n  ".join(problems[:20]))
        print(f"D: ok ({rows})")


def bench(rows, steps=None):
    with tempfile.TemporaryDirectory() as d:
        got, timings, cold, pss, gpu = scripted(rows, Path(d), steps)
    problems = reference.compare(got, reference.expected(rows), steps=steps)
    lat, g, comp = summary(timings)
    r = lambda x: round(x, 3)  # noqa: E731
    print(json.dumps({
        "build": "D omxcode + omxcore", "rows": rows, "steps": len(lat), "device": timings["device"], "correct": not problems,
        "input_to_pixels_ms": {"median": r(statistics.median(lat)), "p95": r(pct(lat, 0.95)), "worst": r(max(lat))},
        "gpu_compute_ms": {"median": r(statistics.median(g)), "p95": r(pct(g, 0.95)), "worst": r(max(g))},
        "job_compute_ms": {"median": r(statistics.median(comp)), "p95": r(pct(comp, 0.95)), "worst": r(max(comp))},
        "cold_start_ms": round(cold, 1), "first_dashboard_ms_in_app": timings["first_dashboard_ms"],
        "data_load_ms": {"read": timings["read_ms"], "cents": timings["cents_ms"], "upload": timings["upload_ms"]},
        "peak_pss_mib": round(pss, 1), "peak_gpu_mib": gpu, "gpu_table_bytes": timings["gpu_table_bytes"],
    }))


def shot(rows, png):
    headless.ensure()
    env = dict(os.environ, MOJOUI_TEST="pause:8000", MOJOUI_SHOT=str(Path(png).resolve()), DASH_ROWS=rows)
    subprocess.run([str(APP)], cwd=ROOT, env=env, check=True, stdout=subprocess.DEVNULL, timeout=300)
    print(png)


if __name__ == "__main__":
    args = sys.argv[1:]
    s = int(args[args.index("--steps") + 1]) if "--steps" in args else None
    if "--no-build" not in args:
        build()
    if "--shot" in args:
        i = args.index("--shot")
        shot(args[i + 1], args[i + 2])
    elif "--bench" in args:
        bench(args[args.index("--bench") + 1], s)
    else:
        check(s)
