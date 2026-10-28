"""Build C of goal 36 (omxcode): proves examples/particles against showcase/SPEC.md.

    pixi run python showcase/omxcode/check_c.py                  # build, scripted N=10000 F=120, compare: "C: ok"
    pixi run python showcase/omxcode/check_c.py --bench N FRAMES # JSON: median frame/step/work ms, cold start, peak RSS
    pixi run python showcase/omxcode/check_c.py --shot N OUT.png  # the window after 3 s at N particles
    (--no-build: use the binary already built)

The app runs in the real GTK host on the headless display (scripts/headless.py), stepping and drawing on the GPU.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402

APP = ROOT / "build/particles/linux/particles"


def build():
    r = subprocess.run(["scripts/build.sh", "particles", "linux"], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0 or not APP.exists():
        sys.exit("C: FAIL build\n" + "\n".join(l for l in (r.stdout + r.stderr).splitlines() if "error" in l)[:4000])


def scripted(n, frames, out, positions=True, env=None):
    """Runs the app scripted; returns (timings, cold start ms to the first drawn frame, peak RSS MiB)."""
    headless.ensure()
    t0 = time.perf_counter()
    p = subprocess.Popen([str(APP), "--scripted", "--n", str(n), "--frames", str(frames), "--out", str(out)]
                         + ([] if positions else ["--positions", "0"]),
                         cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=dict(os.environ, **(env or {})))
    cold = None
    log = []
    for line in p.stdout:
        log.append(line)
        if cold is None and "first frame" in line:
            cold = (time.perf_counter() - t0) * 1000
    _, status, usage = os.wait4(p.pid, 0)
    p.returncode = os.waitstatus_to_exitcode(status)
    if p.returncode != 0 or not (out / "timings.json").exists():
        sys.exit(f"C: FAIL scripted run (exit {p.returncode})\n" + "".join(log[-30:]))
    return json.loads((out / "timings.json").read_text()), cold, usage.ru_maxrss / 1024


def check():
    build()
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        timings, cold, rss = scripted(10_000, 120, d)
        ref = d / "ref.bin"
        subprocess.run([sys.executable, "showcase/reference.py", "10000", "120", str(ref)], cwd=ROOT, check=True)
        got = np.fromfile(d / "positions.bin", "<f4").reshape(-1, 2)
        want = np.fromfile(ref, "<f4").reshape(-1, 2)
        if got.shape != want.shape:
            sys.exit(f"C: FAIL positions shape {got.shape} vs {want.shape}")
        close = np.all(np.abs(got - want) <= 1e-3, axis=1)
        share = close.mean()
        worst = np.abs(got - want).max()
        frames = len(timings["step"])
        print(f"  {timings['device']}: {frames} frames, step median {np.median(timings['step']):.3f} ms, "
              f"frame median {np.median(timings['total'][1:]):.2f} ms; cold start {cold:.0f} ms, peak {rss:.0f} MiB")
        print(f"  positions within 1e-3 of the NumPy reference: {share * 100:.3f} % (worst {worst:.2e})")
        if frames != 120 or len(timings["total"]) != 120 or share < 0.999:
            sys.exit("C: FAIL")
    print("C: ok")


def bench(n, frames, warm=60):
    with tempfile.TemporaryDirectory() as d:
        timings, cold, rss = scripted(n, frames + warm, Path(d))
    pick = lambda k: float(np.median(timings[k][warm:]))  # noqa: E731
    print(json.dumps({
        "build": "C omxcode", "n": n, "frames": frames, "warmup": warm, "device": timings["device"],
        "median_frame_ms": round(pick("total"), 3), "median_step_ms": round(pick("step"), 3),
        "median_work_ms": round(pick("work"), 3), "fps": round(1000 / pick("total"), 1),
        "cold_start_ms": round(cold, 1), "peak_rss_mib": round(rss, 1),
    }))


def shot(n, png):
    headless.ensure()
    env = dict(os.environ, MOJOUI_TEST="pause:3000", MOJOUI_SHOT=str(Path(png).resolve()), PARTICLES_N=str(n))
    subprocess.run([str(APP)], cwd=ROOT, env=env, check=True, stdout=subprocess.DEVNULL, timeout=120)
    print(png)


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--shot" in args:
        i = args.index("--shot")
        if "--no-build" not in args:
            build()
        shot(int(args[i + 1]), args[i + 2])
        sys.exit(0)
    if "--bench" in args:
        i = args.index("--bench")
        if "--no-build" not in args:
            build()
        bench(int(args[i + 1]), int(args[i + 2]))
    else:
        check()
