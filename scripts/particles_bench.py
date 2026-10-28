"""Goal 36 M4: one measurement protocol for every row of the particle showcase (showcase/SPEC.md).

    pixi run python scripts/particles_bench.py                 # build, measure every row and size, count the code
    pixi run python scripts/particles_bench.py --rows A C --sizes 1000000 --runs 1   # a quick subset (not written)
    pixi run python scripts/particles_bench.py --count         # only the code/effort counts (printed)

Writes docs/goals/36/results.json and docs/goals/36/results.md (full runs only).

    pixi run python scripts/particles_bench.py --desktop       # goal 36b M7: the same protocol on the live desktop

--desktop (goal 36b, D-735): every row on the owner's Hyprland desktop (Wayland, GPU-composited) instead of Xvfb:
C in GTK on Wayland (GTK's GL renderer, GPU canvas pictures handed over without a readback, the field at 1280×720
pixels: MOJOUI_CANVAS_SCALE=1), A and A-cpu and B-wasm in headed Chromium on Wayland (the same binary and flags for
all three, vsync and the frame limiter off), B-native in a Wayland window (B-native) and offscreen as before
(B-native-off), plus C's feature rows at 1M/5M/20M (each 36b feature switched off in turn, FEATURES below). Same gate,
same 60 + 600 frames, 3 runs, median ± spread. Writes results-desktop.json/.md and present-desktop.json.

The protocol, the same for all rows:
- One build at a time, nothing else running: the quiet gate. Before every run (each row and size, each of the three
  runs, B-wasm's thread probes) it waits until the 1-minute load average is < GATE_LOAD and no other process holds
  the GPU (nvidia-smi compute apps not started by this script, above GATE_IDLE_MIB: the desktop's idle graphics
  clients hold 6 MiB each), polling every 60 s, for up to 4 hours of waiting in all; if the machine never gets quiet it stops
  and writes nothing. Each run records the load and the compute apps it started with.
  --provisional: no gate and no waiting (a busy machine); written as results-provisional.json/.md, marked PROVISIONAL.
- A, A-cpu and C run on the same Xvfb display (scripts/headless.py); B-wasm runs in headless Chromium on the same GPU;
  B-native renders offscreen (NVIDIA's Vulkan driver can't present to Xvfb). Every GPU row asserts an NVIDIA adapter
  (never SwiftShader or llvmpipe).
- 60 warm-up frames, then 600 measured; three runs; each figure is the median of the three runs' figures, with the
  spread (max - min). Within a run the headline is a mean (below), not a median.
- Headline frame ms = throughput: the measured window's wall time / 600 (the mean interval between frame starts,
  vsync and frame limiters off). Not the median interval: a pipelined loop runs in bursts (A's median rAF interval
  was 0.5 ms while its GPU needed 2.8 ms a frame), so only the mean counts every frame's work.
    A: &await=0, the queue drained at frame 60, wall time to the last frame's GPU completion (window_ms_per_frame).
    A-cpu, B-wasm: rAF interval (Chromium --disable-gpu-vsync --disable-frame-rate-limit).
    B-native: its loop's interval (offscreen, two frames in flight).
    C: the canvas frame interval with GDK_DEBUG=no-vsync (GTK's frame clock otherwise caps it at 60 fps: verified,
       16.7 ms at every N).
- "Holds 60 fps" at N: headline <= 16.7 ms and the 95th-percentile interval <= 20 ms.
- Reported separately, labelled: step ms (GPU timestamps for A and B-native, C's separate timed pass, the CPU for
  A-cpu and B-wasm), GPU frame ms, CPU encode ms, C's readback ms.
- Cold start: from just before the process (or browser) is launched to the first drawn frame (its work done).
- Peak memory: one method for all rows: this script samples the process tree it launched (the harness's own Python,
  Node (Playwright) and nvidia-smi excluded; GPU memory not counted): RSS every 20 ms, and PSS (proportional set size,
  /proc/<pid>/smaps_rollup, as smem reports it: a page shared by k processes counts 1/k in each) every 100 ms. PSS is the
  headline: RSS counts a shared page once per process, which inflates a multi-process browser. No row copies its
  positions out at the end (positions off).
"""
import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
for d in ("showcase/js-webgpu", "showcase/js-rust", "showcase/omxcode"):
    sys.path.insert(0, str(ROOT / d))
import headless  # noqa: E402

OUT = ROOT / "docs/goals/36"
ROWS = ["A", "A-cpu", "B-wasm", "B-native", "C"]
SIZES = [1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000]
EXTRA = {"A-cpu": [100_000]}
WARM, MEAS, RUNS = 60, 600, 3
FRAME_60 = 1000 / 60  # 16.7 ms
P95_MAX = 20.0
GATE_LOAD = 2.0  # the quiet gate: 1-minute load average below this
GATE_IDLE_MIB = 16  # GPU compute apps at or under this (idle desktop graphics clients) don't count as busy
GATE_POLL_S = 60
GATE_BUDGET_S = 4 * 3600
LABEL = {
    "A": "A · JS + WebGPU", "A-cpu": "A-cpu · plain JS (CPU)", "B-wasm": "B-wasm · JS + Rust/wasm",
    "B-native": "B-native · Rust + wgpu", "C": "C · omxcode (Mojo)",
}
DESKTOP = False  # --desktop (goal 36b M7)
DESKTOP_ROWS = ["A", "A-cpu", "B-wasm", "B-native", "B-native-off", "C"]
# C's 36b features switched off in turn (D-743), at FEATURE_SIZES: the per-feature effect
FEATURES = {
    "C-36": {"MOJOUI_CANVAS_GPU": "0", "MOJOUI_SPLAT_ATOMICS": "3"},  # goal 36's path, on this desktop
    "C-36gl": {"MOJOUI_CANVAS_GPU": "0", "MOJOUI_SPLAT_ATOMICS": "3", "GSK_RENDERER": "gl"},  # the same, on GTK's GL renderer
    "C+M6": {"MOJOUI_SPLAT_ATOMICS": "3", "MOJOUI_BLEND": "0"},  # + zero-copy presentation
    "C+M6c": {"MOJOUI_BLEND": "0"},  # + the two-atomic splat (C itself adds M6b: blending, measured at run time)
    "C-blend": {"MOJOUI_BLEND": "1"},  # M6b always on (hardware blending every frame)
    "C-hidpi": {"MOJOUI_CANVAS_SCALE": ""},  # C at the screen's own scale (1.6: 2048×1152 pixels)
}
FEATURE_SIZES = [1_000_000, 5_000_000, 20_000_000]
LABEL.update({
    "B-native-off": "B-native · Rust + wgpu (offscreen)",
    "C-36": "C · goal 36's path (readback, 3 atomics)", "C-36gl": "C · goal 36's path on GTK's GL renderer", "C+M6": "C · + M6 zero-copy", "C+M6c": "C · + M6c packed splat",
    "C-blend": "C · M6b blending always", "C-hidpi": "C · at the screen's 1.6× (2048×1152)",
})
# Chromium on Wayland for A, A-cpu and B-wasm alike: the binary (not /usr/bin/chromium, whose wrapper adds the
# desktop's own flags and extensions), no Vulkan compositing (Chromium refuses it on Wayland), WebGPU through Dawn
DESKTOP_CHROME = "/usr/lib/chromium/chromium"
DESKTOP_A_FLAGS = [
    "--ozone-platform=wayland", "--enable-unsafe-webgpu", "--disable-gpu-sandbox", "--enable-webgpu-developer-features",
    "--ignore-gpu-blocklist", "--no-first-run", "--no-default-browser-check", "--disable-extensions",
    "--password-store=basic", "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
    "--disable-backgrounding-occluded-windows", "--window-size=1280,800",
]
DESKTOP_C_ENV = {"GDK_BACKEND": "wayland", "MOJOUI_CANVAS_SCALE": "1", "MOJOUI_PRESENT_STATS": "1", "GSK_DEBUG": "renderer"}


def use_desktop():
    """--desktop: the owner's Wayland session for every row (D-735); never the headless display."""
    global DESKTOP, OUT_JSON
    wl = os.environ.get("WAYLAND_DISPLAY")
    rt = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    if not wl or not (rt / wl).exists():
        raise SystemExit("particles_bench --desktop: no Wayland desktop (WAYLAND_DISPLAY)")
    DESKTOP = True
    LABEL["B-native"] = "B-native · Rust + wgpu (in a window)"
    os.environ["MOJOUI_HEADLESS"] = "0"
    for k in ("GSK_RENDERER", "GDK_DISABLE", "GDK_SCALE", "GDK_BACKEND", "MOJOUI_PRIVATE_DISPLAY"):
        os.environ.pop(k, None)
    import check_a
    import check_b
    check_a.CHROME = DESKTOP_CHROME
    check_a.FLAGS = DESKTOP_A_FLAGS
    check_b.CHROMIUM = DESKTOP_CHROME
    check_b.HEADLESS_ARGS = ["--ozone-platform=wayland", "--disable-extensions", "--password-store=basic",
                             "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"]


def desktop_setup():
    """What the desktop run ran on, recorded with the results."""
    def sh(*cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.strip()
        except Exception as e:
            return f"({e})"
    mon = {}
    try:
        m = json.loads(sh("hyprctl", "monitors", "-j"))[0]
        mon = {k: m.get(k) for k in ("name", "description", "width", "height", "refreshRate", "scale", "vrr", "dpmsStatus", "activelyTearing")}
    except Exception as e:
        mon = {"error": str(e)}
    return {
        "compositor": sh("hyprctl", "version").splitlines()[0] if sh("hyprctl", "version") else "?",
        "monitor": mon, "wayland_display": os.environ.get("WAYLAND_DISPLAY"),
        "gtk": sh("pkg-config", "--modversion", "gtk4"), "chromium": sh(DESKTOP_CHROME, "--version"),
        "vsync": "off for every row: C GDK_DEBUG=no-vsync (GTK's frame clock uncapped); A, A-cpu, B-wasm Chromium "
                 "--disable-gpu-vsync --disable-frame-rate-limit; B-native wgpu present mode Immediate (in a window the "
                 "compositor still paces it) or offscreen",
        "canvas_pixels": "1280×720 for every row (C: MOJOUI_CANVAS_SCALE=1; the browsers' and wgpu's canvases are 1280×720 "
                         "pixels and the compositor or browser scales them to the 1.6× monitor); C-hidpi: 2048×1152",
        "windows": "each row's window opens tiled on the active workspace beside the one window already there; "
                   "closed after its run",
    }


# the sources a result was built from (freshness: m4 recomputes this)
SOURCES = ["showcase", "examples/particles", "mojoui", "themes", "scripts/particles_bench.py", "scripts/headless.py",
           "scripts/build.sh"]


# ---------- the machine ----------

def sources_sha():
    files = subprocess.run(["git", "ls-files", *SOURCES], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    h = hashlib.sha256()
    for f in sorted(files):
        if f.endswith(".png") or not (ROOT / f).is_file():
            continue
        h.update(f.encode() + b"\0" + (ROOT / f).read_bytes() + b"\0")
    return h.hexdigest()


def dirty():
    return subprocess.run(["git", "status", "--porcelain", "--", *SOURCES], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def gpu_util():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout
        return max(int(x) for x in out.split())
    except Exception:
        return -1


def ours():
    """Pids this script started (its descendants)."""
    kids = {}
    for p in Path("/proc").iterdir():
        if p.name.isdigit():
            try:
                st = (p / "stat").read_text()
                kids.setdefault(int(st[st.rindex(")") + 2:].split()[1]), []).append(int(p.name))
            except (OSError, ValueError, IndexError):
                pass
    out, todo = set(), [os.getpid()]
    while todo:
        q = todo.pop()
        out.add(q)
        todo += kids.get(q, [])
    return out


def compute_apps():
    """nvidia-smi --query-compute-apps=pid,process_name,used_memory: [(pid, name, MiB)]."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-compute-apps=pid,process_name,used_memory", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception as e:
        return [(-1, f"nvidia-smi failed: {e}", -1)]
    apps = []
    for line in out.splitlines():
        f = [x.strip() for x in line.split(",")]
        if len(f) >= 3 and f[0].isdigit():
            apps.append((int(f[0]), f[1], int(f[2]) if f[2].isdigit() else -1))
    return apps


class NotQuiet(Exception):
    pass


class Gate:
    """The quiet gate: load < GATE_LOAD and no other process on the GPU; 4 hours of waiting in all (the runs' own time
    doesn't count against it)."""

    def __init__(self, log):
        self.log, self.waited = log, 0

    def wait(self, what):
        t0 = time.time()
        while True:
            load, mine = os.getloadavg()[0], ours()
            apps = compute_apps()
            busy = [a for a in apps if a[0] not in mine and (a[2] > GATE_IDLE_MIB or a[2] < 0)]
            if load < GATE_LOAD and not busy:
                w = round(time.time() - t0)
                self.waited += w
                if w:
                    self.log(f"  (quiet after {w} s: load {load:.2f})")
                return {"gated": True, "load1": round(load, 2), "waited_s": w,
                        "compute_apps": [f"{pid},{name},{mib} MiB" for pid, name, mib in apps]}
            if self.waited + (time.time() - t0) > GATE_BUDGET_S:
                raise NotQuiet(f"never quiet before {what}: load {load:.2f}, GPU held by "
                               + "; ".join(f"{pid} {Path(name).name} {mib} MiB" for pid, name, mib in busy))
            if time.time() - t0 < 1 or int(time.time() - t0) % 600 < GATE_POLL_S:
                self.log(f"  (waiting for quiet before {what}: load {load:.2f}, {len(busy)} other GPU apps)")
            time.sleep(GATE_POLL_S)


def wait_quiet(log):
    """--provisional: no waiting (the machine is known to be busy); records the load and the GPU's compute apps."""
    return {"gated": False, "load1": round(os.getloadavg()[0], 2), "gpu_util": gpu_util(), "waited_s": 0,
            "compute_apps": [f"{pid},{name},{mib} MiB" for pid, name, mib in compute_apps()]}


_EXCLUDE = {"python", "python3", "python3.13", "node", "nvidia-smi", "pixi", "Xvfb", "sh", "bash"}


class TreeRss:
    """Peak RSS (MB) of every process this script started (its descendants), sampled every 20 ms, and peak PSS (MB),
    from smaps_rollup every fifth sample (100 ms)."""

    def __init__(self):
        self.peak, self.peak_pss, self._stop = 0, 0, threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()

    @staticmethod
    def sample(pss=False):
        kids, comm, rss = {}, {}, {}
        for p in Path("/proc").iterdir():
            if not p.name.isdigit():
                continue
            try:
                stat = (p / "stat").read_text()
                name, rest = stat[stat.index("(") + 1:stat.rindex(")")], stat[stat.rindex(")") + 2:].split()
                pid = int(p.name)
                kids.setdefault(int(rest[1]), []).append(pid)
                comm[pid] = name
                rss[pid] = int(rest[21]) * 4  # rss pages -> kB (4 kB pages)
            except (OSError, ValueError, IndexError):
                pass
        total, ptotal, todo = 0, 0, list(kids.get(os.getpid(), []))
        while todo:
            q = todo.pop()
            todo += kids.get(q, [])
            if comm.get(q) not in _EXCLUDE:
                total += rss.get(q, 0)
                if pss:
                    try:
                        m = re.search(r"^Pss:\s+(\d+) kB", Path(f"/proc/{q}/smaps_rollup").read_text(), re.M)
                        ptotal += int(m.group(1)) if m else 0
                    except OSError:
                        pass
        return total / 1024, ptotal / 1024

    def _run(self):
        i = 0
        while not self._stop.is_set():
            rss, pss = self.sample(pss=i % 5 == 0)
            self.peak = max(self.peak, rss)
            if i % 5 == 0:
                self.peak_pss = max(self.peak_pss, pss)
            i += 1
            self._stop.wait(0.02)

    def stop(self):
        self._stop.set()
        self._t.join()
        return round(self.peak, 1), round(self.peak_pss, 1)


def quiet_harness():
    """The checks' own samplers would add load during the run (A's polled nvidia-smi every 0.2 s, B's /proc scan
    every 20 ms) and measure memory differently: turn them off, so this script's TreeRss is the one method."""
    import check_a
    import check_b
    check_a._gpu_mem_mb = lambda pgid: None
    check_a._tree_rss_mb = lambda pgid: 0.0

    class _NoRss:
        def __init__(self, pid):
            pass

        def stop(self):
            return 0

    check_b.PeakRss = _NoRss


# ---------- one run of one row ----------

def _stats(intervals):
    iv = sorted(x for x in intervals if x is not None)
    return {"median_interval_ms": statistics.median(iv), "p95_interval_ms": iv[min(len(iv) - 1, int(0.95 * len(iv)))],
            "mean_interval_ms": statistics.mean(iv)}


def _med(xs):
    xs = [x for x in (xs or []) if x is not None]
    return statistics.median(xs) if xs else None


def _nvidia(name, row):
    a = (name or "").lower()
    if "nvidia" not in a or "swiftshader" in a or "llvmpipe" in a:
        raise RuntimeError(f"{row}: not on the NVIDIA GPU (adapter: {name})")


def run_a(n, cpu=False):
    import check_a
    frames = WARM + MEAS
    params = "&positions=0" + ("&mode=cpu" if cpu else f"&await=0&window={WARM}")
    t, out, extra = check_a.run(n, frames, params, flags=check_a.UNCAPPED, timeout=120 + frames * 2 + n / 2e4)
    iv = t["raf_interval_ms"][WARM:]
    s = _stats(iv)
    if cpu:
        adapter = t["adapter"]
        head = s["mean_interval_ms"]
        how = "mean rAF interval, vsync/limiter off"
    else:
        adapter = t["adapter"]
        _nvidia(adapter, "A")
        head = t["window_ms_per_frame"]
        how = "window wall time to the last frame's GPU completion / 600 (&await=0, vsync/limiter off)"
    return {
        "frame_ms": head, "frame_ms_is": how, **s,
        "step_ms": _med(t["step_ms"][WARM:]) if t.get("step_ms") else None,
        "step_ms_is": "CPU (plain JS, main thread)" if cpu else "GPU timestamp-query around the step pass",
        "gpu_frame_ms": None if cpu else _med(t["gpu_frame_ms"][WARM:]),
        "cpu_encode_ms": None if cpu else _med(t["cpu_encode_ms"][WARM:]),
        "draw_ms": _med(t["draw_ms"][WARM:]) if cpu and t.get("draw_ms") else None,
        "readback_ms": None,
        "cold_start_ms": extra["cold_start_ms"], "adapter": adapter,
    }, out


def run_b(row, n, threads=None):
    import check_b
    out = Path(tempfile.mkdtemp(prefix="bench_b_"))
    frames = WARM + MEAS
    if row == "B-wasm":
        t = check_b.run_wasm(n, frames, out / "w", threads=threads, positions=False)
        adapter = t["renderer"]
        step_is = f"CPU: wasm step + pack, {t['threads']} threads (wall)"
    else:
        check_b.NATIVE_ARGS = [] if (DESKTOP and row == "B-native") else ["--offscreen"]
        t = check_b.run_native(n, frames, out / "n", positions=False)
        adapter = t["adapter"]
        step_is = "GPU timestamp queries around the compute pass"
    _nvidia(adapter, row)
    iv = t["total"][WARM:]
    s = _stats(iv)
    return {
        "frame_ms": s["mean_interval_ms"],
        "frame_ms_is": ("mean rAF interval, vsync/limiter off" + ("" if DESKTOP else " (headless)")) if row == "B-wasm" else (
            "mean loop interval (a Wayland window, present mode " + str(t.get("present")) + ")" if t.get("present") not in (None, "offscreen")
            and DESKTOP and row == "B-native" else "mean loop interval (offscreen, two frames in flight)"),
        **s, "step_ms": _med(t["step"][WARM:]), "step_ms_is": step_is,
        "gpu_frame_ms": None, "cpu_encode_ms": _med(t["work"][WARM:]) if row == "B-wasm" else None,
        "readback_ms": None, "cold_start_ms": t["cold_start_ms"], "adapter": adapter,
        **({"threads": t["threads"], "crossOriginIsolated": t["crossOriginIsolated"]} if row == "B-wasm" else {"present": t.get("present")}),
    }, out


def run_c(n, row="C"):
    import check_c
    import re as _re
    out = Path(tempfile.mkdtemp(prefix="bench_c_"))
    env = {"GDK_DEBUG": "no-vsync"}
    if DESKTOP:
        env.update(DESKTOP_C_ENV)
        env.update(FEATURES.get(row, {}))
        if env.get("MOJOUI_CANVAS_SCALE") == "":
            env.pop("MOJOUI_CANVAS_SCALE")
            os.environ.pop("MOJOUI_CANVAS_SCALE", None)
    t, cold, _ = check_c.scripted(n, WARM + MEAS, out, positions=False, env=env)
    _nvidia(t["device"], "C")
    s = _stats(t["total"][WARM:])
    step, splat, rb = _med(t["step"][WARM:]), _med(t["splat"][WARM:]), _med(t["readback"][WARM:])
    r = {
        "frame_ms": s["mean_interval_ms"], "frame_ms_is": "mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped)",
        **s, "step_ms": step, "step_ms_is": "GPU step, timed on a separate pass (each part waited for on its own)",
        "gpu_frame_ms": step + splat, "cpu_encode_ms": None, "readback_ms": rb,
        "work_ms": _med(t["work"][WARM:]), "splat_ms": splat,
        "cold_start_ms": cold, "adapter": t["device"],
    }
    if DESKTOP:  # the host's own account of each frame's picture (MOJOUI_PRESENT_STATS)
        log = "".join(check_c.LAST_LOG)
        m = _re.search(r"present stats: gpu_blended (\d+), gpu_copied (\d+), cpu_copied (\d+), .*renderer (\S*)", log)
        if not m:
            raise RuntimeError(f"{row}: no present stats in the app's output")
        b, c, cpu = int(m.group(1)), int(m.group(2)), int(m.group(3))
        used = _re.search(r"Using renderer '(\w+)'", log)  # (GSK_DEBUG=renderer: what GTK actually drew with)
        if not used:
            raise RuntimeError(f"{row}: GTK didn't say which renderer it used")
        r.update({"gpu_blended": b, "gpu_copied": c, "cpu_copied": cpu, "gsk_renderer": m.group(4), "renderer_used": used.group(1),
                  "present_path": next((l.strip() for l in log.splitlines() if l.startswith("mojoui: GPU canvas pictures")), ""),
                  "blend_choices": [l.strip() for l in log.splitlines() if l.startswith("mojoui: additive points")]})
        if cpu == 0:  # no picture went through the CPU in the frame loop: the readback isn't part of these frames
            r["readback_ms"] = None
    return r, out


def one(row, n, threads=None):
    mem = TreeRss()
    try:
        if row in ("A", "A-cpu"):
            r, out = run_a(n, cpu=row == "A-cpu")
        elif row.startswith("B"):
            r, out = run_b(row, n, threads)
        else:
            r, out = run_c(n, row)
    finally:
        peak, peak_pss = mem.stop()
    r["peak_rss_mb"] = peak
    r["peak_pss_mb"] = peak_pss
    subprocess.run(["rm", "-r", "--", str(out)], check=False)  # (only the temp folder this run made)
    return r


# ---------- the protocol ----------

FIELDS = ["frame_ms", "p95_interval_ms", "median_interval_ms", "step_ms", "gpu_frame_ms", "cpu_encode_ms", "readback_ms",
          "work_ms", "splat_ms", "cold_start_ms", "peak_rss_mb", "peak_pss_mb"]


def combine(runs):
    out = {}
    for k in FIELDS:
        xs = [r[k] for r in runs if r.get(k) is not None]
        if xs:
            out[k] = round(statistics.median(xs), 3)
            out[k + "_spread"] = round(max(xs) - min(xs), 3)
    for k in ("frame_ms_is", "step_ms_is", "adapter", "threads", "crossOriginIsolated", "present", "present_path", "gsk_renderer"):
        if k in runs[0]:
            out[k] = runs[0][k]
    if "renderer_used" in runs[0]:
        out["renderer_used"] = sorted({r["renderer_used"] for r in runs})
    for k in ():
        if k in runs[0]:
            out[k] = runs[0][k]
    if "cpu_copied" in runs[0]:  # (C on the desktop: every run's picture path, worst case)
        out["cpu_copied_max"] = max(r["cpu_copied"] for r in runs)
        out["gpu_presented_min"] = min(r["gpu_copied"] + r["gpu_blended"] for r in runs)
        out["gpu_blended_max"] = max(r["gpu_blended"] for r in runs)
        out["blend_choices"] = sorted({c for r in runs for c in r.get("blend_choices", [])})
    out["holds_60"] = out["frame_ms"] <= FRAME_60 and out["p95_interval_ms"] <= P95_MAX
    out["runs"] = runs
    return out


def build(log):
    log("building B (wasm + native) and C ...")
    b = subprocess.run(["bash", "showcase/js-rust/build.sh"], cwd=ROOT, capture_output=True, text=True)
    if b.returncode:
        raise SystemExit("B build failed:\n" + b.stderr[-3000:])
    c = subprocess.run(["scripts/build.sh", "particles", "linux"], cwd=ROOT, capture_output=True, text=True)
    if c.returncode or not (ROOT / "build/particles/linux/particles").exists():
        raise SystemExit("C build failed:\n" + (c.stdout + c.stderr)[-3000:])


def bench(rows, sizes, runs, log, gate=None):
    quiet = (lambda what: gate.wait(what)) if gate else (lambda what: wait_quiet(log))
    results = {}
    for row in rows:
        results[row] = {}
        for n in EXTRA.get(row, []) + ([x for x in FEATURE_SIZES if x in sizes] if row in FEATURES else sizes):
            threads = None
            probe = None
            if row == "B-wasm":  # the pool at every core and at cores - 2: keep the better (one probe run each)
                cores = os.cpu_count()
                tried = {}
                for th in (cores, cores - 2):
                    q = quiet(f"{row} {n} probe {th}")
                    tried[th] = one(row, n, th)["frame_ms"]
                    log(f"  B-wasm {n:>10,} probe {th} threads: {tried[th]:.3f} ms (load {q['load1']})")
                threads = min(tried, key=tried.get)
                probe = {str(k): round(v, 3) for k, v in tried.items()}
            rr = []
            for i in range(runs):
                q = quiet(f"{row} {n} run {i + 1}")
                r = one(row, n, threads)
                r["machine"] = q
                rr.append(r)
                log(f"  {row:8} {n:>10,} run {i + 1}: frame {r['frame_ms']:.3f} ms (p95 {r['p95_interval_ms']:.2f}), "
                    f"step {r['step_ms'] if r['step_ms'] is None else round(r['step_ms'], 3)}, cold {r['cold_start_ms']:.0f} ms, "
                    f"peak {r['peak_pss_mb']:.0f} MB PSS ({r['peak_rss_mb']:.0f} RSS); load {q['load1']}, GPU apps {len(q['compute_apps'])}")
            c = combine(rr)
            c["machine"] = {"load1_max": max(r["machine"]["load1"] for r in rr), "gated": all(r["machine"]["gated"] for r in rr),
                            "compute_apps_at_start": [r["machine"]["compute_apps"] for r in rr]}
            if probe:
                c["thread_probe_ms"] = probe
            results[row][str(n)] = c
    return results


# ---------- code and effort, counted ----------

LANG = {".js": "JavaScript", ".wgsl": "WGSL", ".html": "HTML", ".py": "Python", ".rs": "Rust", ".toml": "TOML",
        ".sh": "Bash", ".mojo": "Mojo"}
BUILDS = {
    # the files a person writes for the build (no checks, screenshots, build outputs or lock files)
    "A": {"dir": "showcase/js-webgpu", "skip": ["check_a.py", "cpu.js"]},
    "A-cpu": {"files": ["showcase/js-webgpu/cpu.js", "showcase/js-webgpu/index.html", "showcase/js-webgpu/serve.py"]},
    "B": {"dir": "showcase/js-rust", "skip": ["check_b.py", "Cargo.lock"]},  # both apps together
    "B-wasm": {"files": ["showcase/js-rust/Cargo.toml", "showcase/js-rust/build.sh", "showcase/js-rust/serve.py",
                         "showcase/js-rust/sim/Cargo.toml", "showcase/js-rust/sim/src/lib.rs", "showcase/js-rust/wasm/Cargo.toml",
                         "showcase/js-rust/wasm/src/lib.rs", "showcase/js-rust/web/index.html", "showcase/js-rust/web/main.js",
                         "showcase/js-rust/web/worker.js"]},
    "B-native": {"files": ["showcase/js-rust/Cargo.toml", "showcase/js-rust/sim/Cargo.toml", "showcase/js-rust/sim/src/lib.rs",
                           "showcase/js-rust/native/Cargo.toml", "showcase/js-rust/native/src/main.rs",
                           "showcase/js-rust/native/src/shader.wgsl"]},
    "C": {"dir": "examples/particles", "skip": []},
}
# C's app is one file, but this goal also added code to the framework it calls (PointCloud's step, splat and their
# test): counted from git, from the commit that set the goal, so the page can say both numbers.
GOAL_BASE = "858eff5"
FRAMEWORK = ["mojoui", "themes", "tests/test_pointcloud_step.mojo", "tests/test_canvas_present.mojo", "tests/test_canvas_blend.mojo"]


def framework_added():
    """Lines (not blank, not only a comment) this goal added to the framework and its tests, per file, from git."""
    diff = subprocess.run(["git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "--unified=0", GOAL_BASE, "--", *FRAMEWORK], cwd=ROOT, capture_output=True,
                          text=True).stdout
    per, cur = {}, None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            cur = line[6:] if line.startswith("+++ b/") else None
        elif cur and line.startswith("+") and not line.startswith("+++"):
            t = line[1:].strip()
            if t and not t.startswith("#") and not t.startswith('"""'):
                per[cur] = per.get(cur, 0) + 1
    return per


def build_files(b):
    spec = BUILDS[b]
    if "files" in spec:
        return [ROOT / f for f in spec["files"]]
    files = subprocess.run(["git", "ls-files", spec["dir"]], cwd=ROOT, capture_output=True, text=True).stdout.split()
    return [ROOT / f for f in files if Path(f).name not in spec["skip"] and Path(f).suffix in LANG]


def code_lines(path):
    """Lines that aren't blank or only a comment (// and /* */; #; <!-- -->; Python/Mojo docstrings)."""
    ext = path.suffix
    n, block, doc = 0, False, None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line:
            continue
        if ext in (".py", ".mojo"):
            if doc:
                if doc in line:
                    doc = None
                continue
            m = re.match(r'^[rbu]?("""|\'\'\')', line)
            if m:
                q = m.group(1)
                if line.count(q) == 1 or line == q:
                    doc = q
                continue  # a docstring line
            if line.startswith("#"):
                continue
        elif ext in (".sh", ".toml"):
            if line.startswith("#"):
                continue
        elif ext == ".html":
            if block:
                if "-->" in line:
                    block = False
                continue
            if line.startswith("<!--"):
                block = "-->" not in line
                continue
        else:  # JS, WGSL, Rust
            if block:
                if "*/" in line:
                    block = False
                continue
            if line.startswith("//"):
                continue
            if line.startswith("/*"):
                block = "*/" not in line
                continue
        n += 1
    return n


def languages(files):
    langs = set()
    for f in files:
        langs.add(LANG[f.suffix])
        text = f.read_text()
        if f.suffix == ".js" and "#version 300 es" in text:
            langs.add("GLSL")  # shaders in JS strings
        if f.suffix == ".html" and "<style" in text:
            langs.add("CSS")
        if f.suffix == ".js" and "createShaderModule" in text and not any(g.suffix == ".wgsl" for g in files):
            langs.add("WGSL")
    return sorted(langs)


def shell_commands(path):
    """The commands a build script runs (continuations joined; comments, set, cd and echo dropped)."""
    cmds, cur = [], ""
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        cur += line.rstrip("\\").strip() + " "
        if line.endswith("\\"):
            continue
        cmd, cur = cur.strip(), ""
        if re.match(r"^(set|cd|echo|OUT=|mkdir)\b", cmd):
            continue
        cmds.append(cmd)
    return cmds


TOOLCHAIN = {
    "cargo": "Rust (rustc + cargo), the wasm32 target and rust-src (build-std for wasm threads)",
    "wasm-bindgen": "wasm-bindgen-cli", "wasm-opt": "binaryen (wasm-opt)", "pixi": "pixi (installs the rest)",
    "scripts/build.sh": "Mojo 1.1 + MAX 26.6 (through pixi)", "python": "Python (a static server)",
}


def effort():
    """Per build: lines of code, files, languages, build steps (clean checkout to running) and toolchains."""
    b_build = shell_commands(ROOT / "showcase/js-rust/build.sh")
    steps = {
        "A": ["python showcase/js-webgpu/serve.py  (any static server)", "open http://127.0.0.1:<port>/index.html in Chromium (WebGPU)"],
        "A-cpu": ["python showcase/js-webgpu/serve.py  (any static server)", "open http://127.0.0.1:<port>/index.html?mode=cpu"],
        "B": ["pixi install  (Rust 1.99, wasm32 std, rust-src, wasm-bindgen-cli, binaryen)", *b_build,
              "python showcase/js-rust/serve.py  (COOP/COEP headers, for wasm threads)", "open http://127.0.0.1:<port>/index.html",
              "target/release/particles-native  (the native row)"],
        "B-wasm": ["pixi install  (Rust 1.99, wasm32 std, rust-src, wasm-bindgen-cli, binaryen)",
                   *[c for c in b_build if "particles-native" not in c],
                   "python showcase/js-rust/serve.py  (COOP/COEP headers, for wasm threads)", "open http://127.0.0.1:<port>/index.html"],
        "B-native": ["pixi install  (Rust 1.99)", *[c for c in b_build if "particles-native" in c],
                     "target/release/particles-native"],
        "C": ["pixi install  (Mojo 1.1, MAX 26.6)", *shell_commands_c(), "build/particles/linux/particles"],
    }
    out = {}
    for b in BUILDS:
        files = build_files(b)
        tools = []
        for s in steps[b]:
            w = s.split()[0]
            t = TOOLCHAIN.get(w) or (TOOLCHAIN["cargo"] if w.startswith("RUSTC_BOOTSTRAP") else None)
            if t == TOOLCHAIN["cargo"] and b == "B-native":
                t = "Rust (rustc + cargo)"
            if t and t not in tools:
                tools.append(t)
        if b in ("A", "A-cpu", "B", "B-wasm"):
            tools.append("Chromium with WebGPU" if b == "A" else "Chromium")
        out[b] = {
            "files": len(files), "lines": sum(code_lines(f) for f in files),
            "by_file": {str(f.relative_to(ROOT)): code_lines(f) for f in files},
            "languages": languages(files), "build_steps": len(steps[b]), "steps": steps[b], "toolchains": tools,
        }
    fw = framework_added()
    out["C"]["framework_added"] = {"lines": sum(fw.values()), "by_file": fw, "since": GOAL_BASE}
    return out


def shell_commands_c():
    return ["scripts/build.sh particles linux"]


# ---------- the report ----------

def largest_60(rows):
    best = None
    for n, r in sorted(rows.items(), key=lambda kv: int(kv[0])):
        if r["holds_60"]:
            best = int(n)
    return best


def fmt(x, d=2):
    return "–" if x is None else f"{x:.{d}f}"


def mill(n):
    return f"{n / 1e6:g}M" if n >= 1e6 else f"{n / 1e3:g}k"


def report(res):
    R = res["rows"]
    L = []
    if res.get("provisional"):
        L.append("# PROVISIONAL · Goal 36 M4 · the particle field, measured on a busy machine\n")
        L.append("**PROVISIONAL: measured without the quiet gate, while another project's builds and GPU tests ran "
                 "(1-minute load up to " + str(max(r["machine"]["load1_max"] for row in R.values() for r in row.values() if "machine" in r))
                 + " on 24 cores, other processes on the RTX 3090; per-row load and GPU apps in the JSON). Not the result.**\n")
    elif res.get("desktop"):
        L.append("# Goal 36b M7 · the particle field on the real desktop\n")
        g = res["protocol"]["gate"]
        L.append(f"Every run passed the quiet gate: 1-minute load < {g['load1_below']} and no other process on the GPU "
                 f"(compute apps over {g['gpu_apps_over_mib']} MiB); waited {g['waited_s']} s in all.\n")
        d = res["setup"]
        m = d["monitor"]
        L.append(f"Setup: {d['compositor'].split(' built')[0]} on Wayland ({d['wayland_display']}), monitor {m.get('name')} "
                 f"{m.get('width')}×{m.get('height')} @ {m.get('refreshRate')} Hz, scale {m.get('scale')}, VRR {m.get('vrr')}, "
                 f"DPMS on {m.get('dpmsStatus')}; GTK {d['gtk']}; {d['chromium']}. Vsync: {d['vsync']}. Pixels: {d['canvas_pixels']}.\n")
    else:
        L.append("# Goal 36 M4 · the particle field, measured\n")
        g = res["protocol"]["gate"]
        L.append(f"Every run passed the quiet gate: 1-minute load < {g['load1_below']} and no other process on the GPU "
                 f"(compute apps over {g['gpu_apps_over_mib']} MiB; idle desktop clients hold 6 MiB); waited {g['waited_s']} s in all.\n")
    L.append(f"Commit `{res['commit']}`, sources sha256 `{res['sources_sha256'][:12]}`, {res['date']}; {res['machine']}.\n"
             f"Protocol: scripts/particles_bench.py (docstring): {WARM} warm-up + {MEAS} measured frames, {RUNS} runs, "
             "each run's frame ms is the mean frame interval (throughput); the table shows the median of the runs (± spread = max - min).\n")
    L.append("## Headline: frame ms (throughput, vsync off) and the largest N at 60 fps\n")
    L.append("Holds 60 fps = frame ms ≤ 16.7 and the 95th-percentile frame interval ≤ 20 ms.\n")
    sizes = SIZES
    L.append("| Row | largest N at 60 fps | " + " | ".join(mill(n) for n in sizes) + " |")
    L.append("|---|---|" + "---|" * len(sizes))
    for row in [r for r in R if r not in FEATURES]:
        big = largest_60(R[row])
        cells = []
        for n in sizes:
            r = R[row].get(str(n))
            cells.append("–" if not r else f"{fmt(r['frame_ms'])} ±{fmt(r['frame_ms_spread'])}" + ("" if r["holds_60"] else " ✗"))
        L.append(f"| {LABEL[row]} | {mill(big) if big else 'none'} | " + " | ".join(cells) + " |")
    if any(r in R for r in FEATURES):
        L.append("\n## Each 36b feature's effect on C (frame ms, the same protocol)\n")
        fs = FEATURE_SIZES
        L.append("| C with (GTK renderer used) | " + " | ".join(mill(n) for n in fs) + " |")
        L.append("|---|" + "---|" * len(fs))
        for row in ["C-36", "C-36gl", "C+M6", "C+M6c", "C", "C-blend", "C-hidpi"]:
            if row in R:
                name = {"C": "C · + M6b (all of 36b: blending measured at run time)"}.get(row, LABEL[row])
                used = "/".join(next(iter(R[row].values())).get("renderer_used", []))
                L.append(f"| {name} ({used}) | " + " | ".join(f"{fmt(R[row][str(n)]['frame_ms'])} ±{fmt(R[row][str(n)]['frame_ms_spread'])}"
                                                    if str(n) in R[row] else "–" for n in fs) + " |")
        steps = [("GTK's GL renderer instead of its Vulkan one (goal 36's path both)", "C-36", "C-36gl"),
                 ("M6 the picture kept on the GPU (no readback, no CPU hand-over; GL renderer both)", "C-36gl", "C+M6"),
                 ("M6c packed splat", "C+M6", "C+M6c"), ("M6b blending, measured", "C+M6c", "C")]
        L.append("\nEffect of each (frame ms saved, before → after): " + "; ".join(
            f"{name}: " + ", ".join(f"{mill(n)} {fmt(R[a][str(n)]['frame_ms'] - R[b][str(n)]['frame_ms'])}" for n in fs
                                    if str(n) in R.get(a, {}) and str(n) in R.get(b, {})) for name, a, b in steps if a in R and b in R) + ".")
    if "100000" in R.get("A-cpu", {}):
        r = R["A-cpu"]["100000"]
        L.append(f"\nA-cpu at 100k: {fmt(r['frame_ms'])} ms ±{fmt(r['frame_ms_spread'])}"
                 f" ({'holds' if r['holds_60'] else 'does not hold'} 60 fps; p95 {fmt(r['p95_interval_ms'])} ms).")
    L.append("\nHow each row's frame ms is measured:\n")
    for row in R:
        r = next(iter(R[row].values()))
        L.append(f"- {LABEL[row]}: {r['frame_ms_is']}.")
    L.append("\n## Separately (labelled; not comparable across rows unless the label matches)\n")
    L.append("| Row | N | p95 interval | step ms | step is | GPU frame ms | CPU encode ms | readback ms | cold start ms | peak PSS MB | peak RSS MB |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|")
    for row in R:
        for n, r in sorted(R[row].items(), key=lambda kv: int(kv[0])):
            L.append(f"| {row} | {mill(int(n))} | {fmt(r.get('p95_interval_ms'))} | {fmt(r.get('step_ms'), 3)} | {r['step_ms_is']} | "
                     f"{fmt(r.get('gpu_frame_ms'), 3)} | {fmt(r.get('cpu_encode_ms'), 3)} | {fmt(r.get('readback_ms'), 3)} | "
                     f"{fmt(r.get('cold_start_ms'), 0)} | {fmt(r.get('peak_pss_mb'), 0)} | {fmt(r.get('peak_rss_mb'), 0)} |")
    L.append("\nGPU frame ms: A = GPU timestamps from the step's start to the tone pass's end; C = its timed step + splat "
             "(the separate pass). CPU encode: A = JS encode + submit; B-wasm = step + pack + upload + draw call on the CPU. "
             "C's work per frame (step + splat + readback, one wait) is in results.json (work_ms).")
    if "B-wasm" in R:
        L.append("\nB-wasm thread probe (one run each, frame ms; the better count was used): " + "; ".join(
            f"{mill(int(n))}: {r.get('thread_probe_ms')}" for n, r in sorted(R["B-wasm"].items(), key=lambda kv: int(kv[0]))))
    E = res["effort"]
    L.append("\n## Code and effort (counted by scripts/particles_bench.py, not by hand)\n")
    L.append("| Build | lines of code | files | languages | build steps | toolchains to install |")
    L.append("|---|---|---|---|---|---|")
    for b, e in E.items():
        name = {"B": "B (both apps: wasm and native)"}.get(b, b)
        L.append(f"| {name} | {e['lines']} | {e['files']} | {', '.join(e['languages'])} | {e['build_steps']} | {'; '.join(e['toolchains'])} |")
    fw = E["C"].get("framework_added", {})
    L.append("\nLines exclude blank and comment-only lines (and docstrings). B-wasm and B-native share the sim crate and the "
             "workspace Cargo.toml (counted in both); B is the two apps together. C counts the app (examples/particles) only: "
             "mojoui (the framework) is a library, as WebGPU, wgpu, wasm-bindgen and rayon are. But this goal also added "
             f"{fw.get('lines', 0)} lines to the framework and its tests for C ("
             + ", ".join(f"{f} +{n}" for f, n in fw.get("by_file", {}).items())
             + f"; added lines that aren't blank or a comment, git diff from {fw.get('since')}): PointCloud's step, splat and "
             "readback, reusable by any app. Build steps, clean checkout to running:\n")
    for b, e in E.items():
        L.append(f"- {b}: " + " → ".join(f"`{s}`" for s in e["steps"]))
    L.append("\n## Caveats (every one)\n")
    for c in res.get("caveats", CAVEATS):
        L.append(f"- {c}")
    return "\n".join(L) + "\n"


DESKTOP_CAVEATS = [
    "The desktop: the owner's Hyprland session (Wayland, GPU-composited), measured while the owner was away (D-735); "
    "each row's window opened tiled on the active workspace beside one other window and was closed after its run. The "
    "monitor runs at 59.97 Hz, scale 1.6, VRR and tearing off. With vsync off, GTK and Chromium render frames faster "
    "than the screen shows them (the compositor shows the newest); the headline is frames rendered (throughput), as in goal 36.",
    "Every field is 1280 × 720 pixels: C with MOJOUI_CANVAS_SCALE=1 (GTK scales the texture to the 1.6× monitor on the "
    "GPU), the browsers' canvases are 1280 × 720 pixels at any scale, wgpu's surface is 1280 × 720 physical pixels. "
    "C-hidpi shows C at the screen's own scale (2048 × 1152 pixels, 2.56× the pixels).",
    "C on the desktop: GTK 4.22 on Wayland with its GL renderer (asked for by the framework when CUDA↔GL works, D-737); "
    "the picture goes from CUDA memory into a GL texture GPU→GPU (or is blended into one), no readback: each run's "
    "present counters (gpu_copied, gpu_blended, cpu_copied = 0) are in results-desktop.json. The host waits for the "
    "GPU once a frame before GTK draws (NVIDIA stalls GL behind queued CUDA work, D-746); one frame in flight is opt-in "
    "and off here (D-747). The renderer GTK actually drew with is recorded for every C run (GSK_DEBUG=renderer): goal "
    "36's path (C-36) uses GTK's default, Vulkan; C-36gl is the same path on GL, so the renderer and the readback "
    "are measured apart.",
    "C's additive points use the compute splat, and blending is measured against it after 120 frames and then 240, "
    "480… (D-739): inside the 600 measured frames that is two short measurements (6 frames of the splat, then blending "
    "until it is clearly slower, at most 6 frames); C-blend has blending on every frame.",
    "C's splat is the framework's PointCloud.splat: two atomics per particle (M6c; C-36 and C+M6 run goal 36's three), "
    "each channel skipped once saturated, exact (GPU = CPU picture).",
    "C's step ms and GPU frame ms come from a separate timed pass after the measured frames (each part waited for on its "
    "own), with the compute splat; readback ms is shown only for rows whose frames copy the picture to the CPU (C-36).",
    "A, A-cpu and B-wasm run in headed Chromium 152 on Wayland (/usr/lib/chromium/chromium, the same flags for all three; "
    "Chromium refuses Vulkan compositing on Wayland, so it composites with GL; WebGPU uses Dawn on Vulkan). Goal 36 ran "
    "B-wasm headless through the /usr/bin/chromium wrapper.",
    "A draws with an atomic compute rasteriser (two u32 atomics per on-screen particle, skipped once the pixel is "
    "saturated, the same load-first form as C); A's headline is &await=0 with the queue drained at the warm-up's end, "
    "as in goal 36. B draws with hardware blending (WebGL2 points / wgpu point list, additive).",
    "B-native in a Wayland window is paced by the compositor, about one frame per screen refresh at every N, with present "
    "mode Immediate or Mailbox (both tried in a probe, both offered by the driver; that probe read 18.5 ms a frame, and "
    "GTK with its frame clock capped read 18.8 ms then). Its throughput is only measurable offscreen, so B-native-off is "
    "the same binary offscreen (two frames in flight), as in goal 36.",
    "A-cpu is single-threaded by design (plain JS on the main thread). B-wasm's thread count is chosen by its own probe.",
    "Peak memory is the PSS of the launched process tree, as in goal 36; GPU memory is not included. Cold start "
    "includes each runtime's own start.",
    "The machine has two RTX 3090s; the compositor and GTK's GL run on the second (CUDA 1), and the framework puts C's "
    "GPU work there too (D-738); A, B pick their own.",
]


CAVEATS = [
    "A draws with an atomic compute rasteriser (two u32 atomics per on-screen particle): it loads the pixel's count first "
    "and skips both atomics once the pixel is saturated (past the tone map's white for the dimmest channel), as C does; "
    "its look is a tone map, not the SPEC's clamp. ?render=points (hardware point blending) exists and is not measured here.",
    "C's splat is the framework's generic PointCloud.splat: two atomics per particle since goal 36b M6c (red and green "
    "packed in one 64-bit atomic, blue in a 32-bit one; goal 36 measured three u32 atomics), each channel skipped once "
    "its sum is saturated (an atomic load first; exact: the GPU still matches the CPU path). That skip was "
    "modelled on A's (a fair-play fix after review); A then got C's load-first form, so both skip the same way.",
    "B draws with hardware blending (WebGL2 points / wgpu point list, additive). B-wasm steps on the CPU (wasm SIMD + a "
    "rayon pool in a worker) and uploads one packed u32 per particle to the GPU every frame.",
    "C copies its finished picture (1280 × 720 × 4 bytes) from the GPU to the CPU every frame and hands it to GTK as a "
    "texture here: on Xvfb there is no GL, so the framework's zero-copy path (goal 36b M6) reports it can't be used "
    "and falls back to this copy. readback ms is that copy alone, measured on the separate pass. On a real desktop "
    "there is no readback (results-desktop.md).",
    "C's step ms comes from a separate timed pass after the measured frames (Mojo 1.1's DeviceEvent has no elapsed time; "
    "the frame loop waits for the GPU once a frame, so it can't split step from splat).",
    "C runs in the real GTK host on Xvfb, where GTK composites with its cairo (software) renderer; on a real display GTK "
    "uses its GL renderer. A and A-cpu run in Chromium on the same Xvfb display (ANGLE/Vulkan, no Vulkan surface).",
    "C's frame clock is capped at 60 fps by GTK unless GDK_DEBUG=no-vsync (verified: 16.7 ms at every N with the cap, "
    "4.8 ms at 1M without), so its headline is measured uncapped.",
    "A's headline comes from &await=0 with the queue drained at the warm-up's end: Chromium's onSubmittedWorkDone round "
    "trip (5-9 ms here) would otherwise dominate, and the rAF interval alone runs ahead of the GPU. So A's p95 is a rAF "
    "interval that runs ahead of the GPU: for A the p95 test never binds, the throughput figure does.",
    "A's CPU encode reads 0.100 ms at every size: Chromium clamps performance.now() to 100 µs on a page that isn't "
    "cross-origin isolated, so it means 'under about 0.1 ms'.",
    "B-wasm's thread count was chosen by its own probe (every core, and cores - 2, one run each; the faster used).",
    "B-native renders offscreen only (NVIDIA's Vulkan driver can't present to Xvfb), two frames in flight: it never "
    "presents to a window here, so its frame, cold start and memory have no window or swapchain in them.",
    "B-wasm runs in headless Chromium (no Xvfb), WebGL2 through ANGLE on NVIDIA's EGL (OpenGL), the fastest path found.",
    "A-cpu is single-threaded by design (plain JS on the main thread, the 'JS alone' baseline); it uses no GPU for the "
    "step, and Chromium composites its canvas.",
    "Peak memory is the PSS of the launched process tree (Chromium's processes, or the one native process), from "
    "smaps_rollup every 100 ms: a page shared by several processes counts once in all. RSS (every 20 ms) is in "
    "results.json too; it counts a shared page once per process, which inflates the multi-process browser rows. GPU "
    "memory is not included. C keeps a CPU copy of all points (16 bytes each) by design of PointCloud.",
    "Cold start includes each runtime's own start: Chromium's for A, A-cpu and B-wasm; the GPU driver's for all.",
    "The machine has two RTX 3090s; each runtime picks its own (all report an NVIDIA GeForce RTX 3090). Each run's "
    "1-minute load and the GPU's compute apps at its start are in results.json.",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", nargs="+", default=ROWS)
    ap.add_argument("--sizes", nargs="+", type=int, default=SIZES)
    ap.add_argument("--runs", type=int, default=RUNS)
    ap.add_argument("--count", action="store_true")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--provisional", action="store_true", help="no quiet gate (busy machine): results marked PROVISIONAL")
    ap.add_argument("--desktop", action="store_true", help="goal 36b M7: every row on the live Wayland desktop")
    a = ap.parse_args()
    if a.desktop:
        use_desktop()
        if a.rows == ROWS:
            a.rows = DESKTOP_ROWS + list(FEATURES)
    if a.count:
        print(json.dumps(effort(), indent=1))
        return
    full = a.rows == (DESKTOP_ROWS + list(FEATURES) if a.desktop else ROWS) and a.sizes == SIZES and a.runs == RUNS
    if full and dirty():
        raise SystemExit("particles_bench: commit the sources first (results must come from a commit):\n" + dirty())
    headless.ensure()
    quiet_harness()
    log = lambda s: print(s, flush=True)  # noqa: E731
    sha = sources_sha()
    if not a.no_build:
        build(log)
    t0 = time.time()
    gate = None if a.provisional else Gate(log)
    try:
        rows = bench(a.rows, a.sizes, a.runs, log, gate)
    except NotQuiet as e:
        raise SystemExit(f"particles_bench: STOPPED, the machine was never quiet within 4 hours ({e}); nothing written")
    if sources_sha() != sha:
        raise SystemExit("particles_bench: the sources changed during the run; results not written")
    gpu = subprocess.run(["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"], capture_output=True, text=True).stdout.strip().splitlines()
    res = {
        "commit": subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
        "sources_sha256": sha, "date": time.strftime("%Y-%m-%d %H:%M"), "seconds": round(time.time() - t0),
        "machine": f"{os.cpu_count()} cores, {', '.join(gpu)}",
        "provisional": bool(a.provisional), "gated": not a.provisional,
        "protocol": {"warmup": WARM, "frames": MEAS, "runs": RUNS, "sizes": SIZES, "extra_sizes": EXTRA,
                     "frame_60_ms": round(FRAME_60, 3), "p95_max_ms": P95_MAX,
                     **({"gate": None} if a.provisional else
                        {"gate": {"load1_below": GATE_LOAD, "gpu_apps_over_mib": GATE_IDLE_MIB, "poll_s": GATE_POLL_S,
                                  "budget_s": GATE_BUDGET_S, "waited_s": gate.waited}})},
        "rows": rows, "largest_n_at_60": {row: largest_60(rows[row]) for row in rows if row not in FEATURES},
        "effort": effort(), "caveats": DESKTOP_CAVEATS if a.desktop else CAVEATS,
        **({"desktop": True, "setup": desktop_setup(), "features": FEATURES, "feature_sizes": FEATURE_SIZES} if a.desktop else {}),
    }
    if not full:
        print(json.dumps({r: {n: {k: v for k, v in x.items() if k != "runs"} for n, x in rows[r].items()} for r in rows}, indent=1))
        return
    OUT.mkdir(parents=True, exist_ok=True)
    name = ("results-desktop-provisional" if a.provisional else "results-desktop") if a.desktop else (
        "results-provisional" if a.provisional else "results")
    (OUT / f"{name}.json").write_text(json.dumps(res, indent=1) + "\n")
    (OUT / f"{name}.md").write_text(report(res))
    print(f"wrote {OUT / name}.json and {name}.md ({res['seconds']} s)")


if __name__ == "__main__":
    main()
