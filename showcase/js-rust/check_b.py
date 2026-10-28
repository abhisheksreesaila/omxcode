"""Goal 36 M2 proof for build B (JS + Rust): both rows scripted, compared with the NumPy reference.

  pixi run python showcase/js-rust/check_b.py                    # build, run both rows at N=10000 F=120, compare
  pixi run python showcase/js-rust/check_b.py --bench ROW N F    # ROW = wasm|native: JSON (median frame/step ms, cold start, peak memory)
  pixi run python showcase/js-rust/check_b.py --shot ROW N FILE.png [--frames F]

Browser row: Chromium 152 (/usr/bin/chromium) headless, WebGL2 through ANGLE on NVIDIA's EGL (the RTX 3090, not
SwiftShader or llvmpipe), vsync and the frame-rate limit off so frame times measure the work. Native row: Vulkan on the RTX 3090; under Xvfb the NVIDIA
driver can't present to the display, so it renders the same frames into a texture (--offscreen, two frames in flight).
"""
import json
import os
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402

NATIVE = HERE / "target/release/particles-native"
CHROMIUM = "/usr/bin/chromium"
CHROME_ARGS = [
    # ANGLE on NVIDIA's EGL (OpenGL). ANGLE on Vulkan also reaches the RTX 3090, but its per-frame buffer upload
    # held 1M particles at ~8.5 ms/frame against ~2 ms here (measured 2026-10-27), so the GL path is the fair best.
    "--use-gl=angle", "--use-angle=gl-egl", "--ignore-gpu-blocklist", "--enable-gpu",
    "--disable-gpu-vsync", "--disable-frame-rate-limit", "--window-size=1280,720",
]
# glvnd would otherwise hand Chromium Mesa's EGL (llvmpipe, a CPU renderer)
CHROME_ENV = {"__EGL_VENDOR_LIBRARY_FILENAMES": "/usr/share/glvnd/egl_vendor.d/10_nvidia.json"}


def build():
    r = subprocess.run(["bash", str(HERE / "build.sh")], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"build failed:\n{r.stdout[-2000:]}\n{r.stderr[-4000:]}")


def tree_rss_kb(pid):
    """Resident memory of a process and its descendants (kB), from /proc."""
    kids = {}
    for p in Path("/proc").iterdir():
        if p.name.isdigit():
            try:
                fields = (p / "stat").read_text().rsplit(")", 1)[1].split()
                kids.setdefault(int(fields[1]), []).append(int(p.name))
            except OSError:
                pass
    total, todo = 0, [pid]
    while todo:
        q = todo.pop()
        todo += kids.get(q, [])
        try:
            for line in Path(f"/proc/{q}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    total += int(line.split()[1])
        except OSError:
            pass
    return total


class PeakRss:
    """Samples a process tree's RSS every 20 ms in the background."""

    def __init__(self, pid):
        self.pid, self.peak, self._stop = pid, 0, threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()

    def _run(self):
        while not self._stop.is_set():
            self.peak = max(self.peak, tree_rss_kb(self.pid))
            time.sleep(0.02)

    def stop(self):
        self._stop.set()
        self._t.join()
        return self.peak


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run_wasm(n, frames, out, shot=None, threads=None):
    """threads: the rayon pool's size (default: navigator.hardwareConcurrency). Cold start counts from before
    Chromium's launch, like the other rows."""
    from playwright.sync_api import sync_playwright

    out.mkdir(parents=True, exist_ok=True)
    port = free_port()
    srv = subprocess.Popen([sys.executable, str(HERE / "serve.py"), "--port", str(port), "--out", str(out)],
                           stdout=subprocess.PIPE, text=True)
    try:
        srv.stdout.readline()
        # Chromium started by us (so its process tree, GPU process included, is ours to measure), driven over CDP
        cdp = free_port()
        profile = tempfile.mkdtemp(prefix="chromium_", dir=out)
        t0 = time.time() * 1000  # (before the browser starts: cold start is launch to first drawn frame)
        chrome = subprocess.Popen([CHROMIUM, "--headless=new", f"--remote-debugging-port={cdp}", f"--user-data-dir={profile}",
                                   "--no-first-run", "--no-default-browser-check", *CHROME_ARGS, "about:blank"],
                                  env={**os.environ, **CHROME_ENV}, stdout=subprocess.DEVNULL, stderr=open(out / "chrome.log", "w"))
        try:
            mem = PeakRss(chrome.pid)
            for _ in range(200):
                try:
                    socket.create_connection(("127.0.0.1", cdp), timeout=0.1).close()
                    break
                except OSError:
                    time.sleep(0.05)
            with sync_playwright() as p:
                browser = p.chromium.connect_over_cdp(f"http://127.0.0.1:{cdp}")
                page = browser.contexts[0].new_page()
                page.set_viewport_size({"width": 1280, "height": 720})
                errors = []
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.on("crash", lambda _: errors.append("renderer crashed"))
                page.on("console", lambda m: m.type == "error" and errors.append(m.text))
                page.goto(f"http://127.0.0.1:{port}/index.html?scripted=1&n={n}&frames={frames}" + (f"&threads={threads}" if threads else ""))
                page.on("console", lambda m: os.environ.get("CHECK_B_VERBOSE") and print("console:", m.type, m.text))
                try:
                    page.wait_for_function("document.title === 'done'", timeout=int(os.environ.get("CHECK_B_TIMEOUT_MS", "600000")), polling=200)
                except Exception as e:
                    readout = page.inner_text("#readout") if not page.is_closed() else "(page closed: see chrome.log)"
                    raise RuntimeError(f"{e}; page errors: {errors}; readout: {readout!r}") from None
                peak = mem.stop()
                if shot:
                    page.screenshot(path=str(shot))
                browser.close()
        finally:
            chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                chrome.kill()
        if errors:
            raise RuntimeError("page errors: " + "; ".join(errors))
        t = json.loads((out / "timings.json").read_text())
        if not t.get("crossOriginIsolated") or t.get("threads", 1) <= 1:
            raise RuntimeError(f"B-wasm ran single-threaded (crossOriginIsolated={t.get('crossOriginIsolated')}, threads={t.get('threads')})")
        t["cold_start_ms"] = t["first_frame_epoch_ms"] - t0
        t["peak_rss_mb"] = peak / 1024
        return t
    finally:
        srv.terminate()
        srv.wait()


def run_native(n, frames, out, shot=None):
    out.mkdir(parents=True, exist_ok=True)
    headless.ensure()
    env = {**os.environ, "WGPU_BACKEND": "vulkan"}
    cmd = [str(NATIVE), "--scripted", "--offscreen", "--n", str(n), "--frames", str(frames), "--out", str(out)]
    ppm = None
    if shot:
        ppm = out / "shot.ppm"
        cmd += ["--shot", str(ppm)]
    t0 = time.time() * 1000
    proc = subprocess.Popen(cmd, env=env, stderr=subprocess.PIPE, text=True)
    mem = PeakRss(proc.pid)
    _, err = proc.communicate(timeout=600)
    peak = mem.stop()
    if proc.returncode:
        raise RuntimeError(f"native exited {proc.returncode}: {err[-2000:]}")
    if shot:
        from PIL import Image
        Image.open(ppm).save(shot)
    t = json.loads((out / "timings.json").read_text())
    t["cold_start_ms"] = t["first_frame_epoch_ms"] - t0
    t["peak_rss_mb"] = peak / 1024
    return t


def compare(positions, ref):
    import numpy as np

    a = np.fromfile(positions, "<f4")
    r = np.fromfile(ref, "<f4")
    if a.shape != r.shape:
        return False, f"size {a.size} != {r.size}"
    err = np.abs(a - r).reshape(-1, 2).max(axis=1)
    frac = float((err <= 1e-3).mean())
    return frac >= 0.999, f"{frac * 100:.3f}% within 1e-3 (max error {err.max():.2e})"


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def summary(t):
    return {
        "row": t["row"], "n": t["n"], "frames": t["frames"],
        "median_frame_ms": round(median(t["total"]), 3),
        "median_step_ms": round(median(t["step"]), 3),
        "cold_start_ms": round(t["cold_start_ms"], 1),
        "peak_rss_mb": round(t["peak_rss_mb"], 1),
        "adapter": t.get("renderer") or t.get("adapter"),
        **({"threads": t["threads"], "step_is": t["step_is"]} if t["row"] == "B-wasm"
           else {"present": t["present"], "step_is": "GPU timestamp queries around the compute pass"}),
    }


ROWS = {"wasm": run_wasm, "native": run_native}


def main():
    a = sys.argv[1:]
    if "--no-build" in a:
        a.remove("--no-build")
    else:
        build()
    tmp = Path(tempfile.mkdtemp(prefix="check_b_"))
    if a[:1] == ["--bench"]:
        row, n, frames = a[1], int(a[2]), int(a[3])
        print(json.dumps(summary(ROWS[row](n, frames, tmp / row))))
        return
    if a[:1] == ["--shot"]:
        row, n, path = a[1], int(a[2]), Path(a[3]).resolve()
        frames = int(a[a.index("--frames") + 1]) if "--frames" in a else 240
        t = ROWS[row](n, frames, tmp / row, shot=path)
        print(json.dumps(summary(t)))
        print(f"shot: {path}")
        return
    n, frames = 10000, 120
    ref = tmp / "ref.bin"
    subprocess.run([sys.executable, str(ROOT / "showcase/reference.py"), str(n), str(frames), str(ref)], check=True)
    ok_all = True
    for row, label in (("wasm", "B-wasm"), ("native", "B-native")):
        try:
            t = ROWS[row](n, frames, tmp / row)
            ok, why = compare(tmp / row / "positions.bin", ref)
            extra = f"{t.get('renderer') or t.get('adapter')}"
        except Exception as e:  # report the row as failed, keep checking the other
            ok, why, extra = False, str(e)[:500], ""
        ok_all &= ok
        print(f"{label}: {'ok' if ok else 'FAIL'}  ({why}; {extra})")
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
