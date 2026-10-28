"""Proof for build A (JS + WebGPU), goal 36 M1.

    pixi run python showcase/js-webgpu/check_a.py                  # N=10,000, 120 frames vs the reference -> "A: ok"
    pixi run python showcase/js-webgpu/check_a.py --bench N FRAMES # JSON: median frame/step ms, cold start, memory
    pixi run python showcase/js-webgpu/check_a.py --shot N FRAMES out.png   # screenshot after F frames

Headless GPU: Chromium runs on the repo's Xvfb display (scripts/headless.py) with real NVIDIA WebGPU through Dawn's
Vulkan backend. The exact command (CHROME + FLAGS below):

    /usr/lib/chromium/chromium --ozone-platform=x11 --enable-unsafe-webgpu --enable-features=Vulkan
        --use-angle=vulkan --disable-vulkan-surface --disable-gpu-sandbox --enable-webgpu-developer-features ...

Why each matters (found by trial on Chromium 152, driver 610): /usr/bin/chromium is a wrapper that adds the desktop's
Wayland flags, so call the binary; x11 because Xvfb is an X server; Xvfb has no GLX, so GL goes through ANGLE on
Vulkan; Chromium's Vulkan presenting to Xvfb crashes the GPU process (exit 139) unless --disable-vulkan-surface;
inside the GPU sandbox Dawn sees only SwiftShader, so --disable-gpu-sandbox; developer features give unquantised
GPU timestamps. Without these the adapter is "google swiftshader" (CPU), which check_a rejects.
"""
import argparse
import json
import os
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(HERE))
import headless  # noqa: E402
import serve  # noqa: E402

CHROME = os.environ.get("CHROME", "/usr/lib/chromium/chromium")
FLAGS = [
    "--ozone-platform=x11", "--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-angle=vulkan",
    "--disable-vulkan-surface", "--disable-gpu-sandbox", "--enable-webgpu-developer-features",
    "--ignore-gpu-blocklist", "--no-first-run", "--no-default-browser-check", "--disable-extensions",
    "--password-store=basic", "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
    "--disable-backgrounding-occluded-windows", "--force-device-scale-factor=1", "--window-position=0,0",
    "--window-size=1280,800",
]


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _gpu_mem_mb(pgid):
    """Framebuffer memory (MB) held by our Chromium's processes, per nvidia-smi pmon (the GPU is shared)."""
    try:
        out = subprocess.run(["nvidia-smi", "pmon", "-c", "1", "-s", "m"], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return None
    total = 0.0
    for line in out.splitlines():
        f = line.split()
        if line.startswith("#") or len(f) < 4 or not f[1].isdigit() or not f[3].isdigit():
            continue
        try:
            if os.getpgid(int(f[1])) == pgid:
                total += float(f[3])
        except ProcessLookupError:
            pass
    return total


def _tree_rss_mb(pgid):
    total = 0
    for d in Path("/proc").iterdir():
        if not d.name.isdigit():
            continue
        try:
            if os.getpgid(int(d.name)) != pgid:
                continue
            for line in (d / "status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    total += int(line.split()[1])
        except (OSError, ProcessLookupError):
            pass
    return total / 1024


UNCAPPED = ["--disable-frame-rate-limit", "--disable-gpu-vsync"]


def run(n, frames, params="", timeout=None, shot=None, flags=()):
    """Runs the page scripted in Chromium; returns (timings, out_dir, extra)."""
    headless.ensure()
    out = Path(tempfile.mkdtemp(prefix="js-webgpu-"))
    srv, st = serve.start(0, out)
    port = srv.server_address[1]
    url = f"http://127.0.0.1:{port}/index.html?scripted=1&n={n}&frames={frames}{params}"
    prof = tempfile.mkdtemp(prefix="js-webgpu-prof-")
    dbg = _free_port() if shot else None
    cmd = [CHROME, f"--user-data-dir={prof}", *FLAGS, *flags, *([f"--remote-debugging-port={dbg}"] if dbg else []), f"--app={url}"]
    t_launch = time.time()
    log = open(out / "chromium.log", "w")
    proc = subprocess.Popen(cmd, stdout=log, stderr=log, start_new_session=True)
    peak = {"rss_mb": 0.0, "gpu_mb": 0.0}
    stop = threading.Event()

    def sample():
        while not stop.is_set():
            peak["rss_mb"] = max(peak["rss_mb"], _tree_rss_mb(proc.pid))
            g = _gpu_mem_mb(proc.pid)
            if g is not None:
                peak["gpu_mb"] = max(peak["gpu_mb"], g)
            stop.wait(0.2)

    threading.Thread(target=sample, daemon=True).start()
    try:
        if not st["done"].wait(timeout or 60 + frames * 0.5 + n / 2e5):
            raise SystemExit(f"A: FAIL timed out (log {out / 'chromium.log'})")
        if (out / "error.txt").exists():
            raise SystemExit("A: FAIL page error: " + (out / "error.txt").read_text())
        if shot:
            time.sleep(0.5)
            from playwright.sync_api import sync_playwright
            with sync_playwright() as p:
                b = p.chromium.connect_over_cdp(f"http://127.0.0.1:{dbg}")
                page = next(pg for c in b.contexts for pg in c.pages if "index.html" in pg.url)
                page.screenshot(path=str(shot))
                b.close()
        timings = json.loads((out / "timings.json").read_text())
    finally:
        stop.set()
        try:
            os.killpg(proc.pid, signal.SIGTERM)  # only the Chromium we started (its own session)
            proc.wait(timeout=10)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        srv.shutdown()
        shutil.rmtree(prof, ignore_errors=True)
    ff = st["events"].get("first_frame", {}).get("t")
    extra = {"cold_start_ms": (ff - t_launch) * 1000 if ff else None, **peak}
    return timings, out, extra


def check_adapter(t):
    a = t["adapter"].lower()
    if "swiftshader" in a or "nvidia" not in a:
        raise SystemExit(f"A: FAIL not on the NVIDIA GPU (adapter: {t['adapter']})")


def correctness(n=10000, frames=120):
    t, out, _ = run(n, frames)
    check_adapter(t)
    ref = out / "ref.bin"
    subprocess.run([sys.executable, str(HERE.parent / "reference.py"), str(n), str(frames), str(ref)], check=True)
    got = np.fromfile(out / "positions.bin", "<f4").reshape(-1, 2)
    want = np.fromfile(ref, "<f4").reshape(-1, 2)
    if got.shape != want.shape:
        raise SystemExit(f"A: FAIL shape {got.shape} != {want.shape}")
    err = np.abs(got - want).max(axis=1)
    frac = float((err <= 1e-3).mean())
    print(f"A: {frac * 100:.3f}% within 1e-3 (max err {err.max():.2e}); median frame {statistics.median(t['total_ms']):.3f} ms"
          + (f", step {statistics.median(t['step_ms']):.4f} ms" if t["step_ms"] else ""))
    if frac < 0.999:
        raise SystemExit("A: FAIL positions differ from the reference")
    print(f"A: ok (adapter: {t['adapter']})")
    shutil.rmtree(out, ignore_errors=True)


def bench(n, frames, warmup, params=""):
    t, out, extra = run(n, frames, "&positions=0" + params)
    check_adapter(t)
    w = warmup if warmup is not None else (60 if frames > 120 else 0)
    med = lambda xs: statistics.median(xs[w:]) if xs else None  # noqa: E731
    iv = [x for x in t["raf_interval_ms"][w:] if x is not None]
    print(json.dumps({
        "build": "js-webgpu", "adapter": t["adapter"], "n": n, "frames": frames, "warmup": w,
        "median_frame_ms": med(t["total_ms"]), "median_step_ms": med(t["step_ms"]), "median_draw_ms": med(t["draw_ms"]), "median_gpu_frame_ms": med(t["gpu_frame_ms"]), "median_cpu_encode_ms": med(t["cpu_encode_ms"]),
        "median_raf_interval_ms": statistics.median(iv) if iv else None,
        "late_frames": round(sum(x > 20 for x in iv) / len(iv), 3) if iv else None,  # rAF gaps > 20 ms
        "cold_start_ms": extra["cold_start_ms"], "init_ms": t["init_ms"],
        "peak_rss_mb": round(extra["rss_mb"], 1), "peak_gpu_mem_mb": extra["gpu_mb"], "js_heap_mb": t["js_heap_mb"],
        "timing": "frame = wall ms from encode to GPU done (awaits onSubmittedWorkDone, whose round trip in Chromium is most of it); gpu_frame/step/draw = GPU timestamp-query; cpu_encode = JS encode+submit; raf_interval with vsync (16.7 = holds 60 fps)",
    }))
    shutil.rmtree(out, ignore_errors=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", nargs=2, type=int, metavar=("N", "FRAMES"))
    ap.add_argument("--warmup", type=int)
    ap.add_argument("--params", default="", help="extra URL params, e.g. &wg=128")
    ap.add_argument("--shot", nargs=3, metavar=("N", "FRAMES", "PNG"))
    a = ap.parse_args()
    if a.bench:
        bench(*a.bench, a.warmup, a.params)
    elif a.shot:
        t, out, _ = run(int(a.shot[0]), int(a.shot[1]), "&positions=0" + a.params, shot=Path(a.shot[2]).resolve())
        print(f"shot: {a.shot[2]} ({t['adapter']})")
    else:
        correctness()
