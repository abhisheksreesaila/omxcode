"""Goal 38 M5: one measurement protocol for the four dashboard builds (showcase-data/SPEC.md), on the live desktop.

    pixi run python scripts/data_bench.py plan                 # the run plan and its expected duration
    pixi run python scripts/data_bench.py selftest [--full]    # the harness's own tests (headless: a fake build)
    pixi run python scripts/data_bench.py env                  # the environment record, printed
    pixi run python scripts/data_bench.py count                # effort only (lines, files, languages, build steps)
    pixi run python scripts/data_bench.py calibrate B          # one build on the desktop: window + KPI-region pictures
    pixi run python scripts/data_bench.py run                  # THE measurement → docs/goals/38/results.json + .md
        [--display headless|desktop]  (default headless: a separate headless Hyprland, screen_observer.HeadlessHyprland)
        [--builds A B C D] [--passes 20] [--runs 3] [--cold 3] [--rows 100M] [--provisional]
    pixi run python scripts/data_bench.py report               # results.md again from results.json

The protocol (docs/goals/38/README.md; the fairness reviewer's, 2026-10-28):
1. Environment recorded (CPU, GPU, driver, kernel, compositor, Chromium/Rust/Mojo/Polars/DuckDB versions, commit,
   data.lock). Quiet gate before every run (and no scripts/check.py running in any worktree): 1-minute load < 0.5 (after GATE_STRICT_S of waiting, < 2 with the value
   recorded), GPU utilisation < 5 %, no other GPU process above 16 MiB except the desktop session's graphics clients
   (processes running before the harness started with only graphics contexts); the screen must be live (unlocked).
2. A separate headless Hyprland on the GPU (default since 2026-10-28: the owner's session is locked; recorded as such
   in results.json, with a caveat), or the owner's live Hyprland desktop (D-765, --display desktop): one window, floated to exactly 1280 × 800 logical pixels, closed after
   its run; only processes this script started are ever stopped. A and B: the same Chromium binary and flags
   (CHROMIUM, CHROMIUM_FLAGS, handed to each driver; the browser's real command line is read back from /proc).
3. Input-to-pixels: CLOCK_MONOTONIC right before the harness writes "step N" to the build's driver → the compositor's
   presentation timestamp of the first frame whose KPI region shows the step's settled content (scripts/
   screen_observer.c: wlr-screencopy of that region only, every composited frame). The build's own stamp ("shown N
   <ms>") is kept beside it.
4. Runs interleaved (round r rotates the order: ABCD, BCDA, CDAB); per run: launch fresh, wait for the first
   dashboard, WARM passes of steps 1…S (discarded), PASSES measured passes, each step after a 300 ms idle gap (counted
   from the KPI region settling), the opening state (step 0) re-applied between passes (not timed); correctness:
   reference.compare on every pass, warm-ups included (any problem voids the run).
5. Cold start: exec of the first process → first dashboard on screen (the observer); split into process start (exec →
   window mapped), data load (the build's own figure) and first frame; COLD runs with the data file evicted from the
   page cache (posix_fadvise DONTNEED, checked with fincore); A and B also without the browser launch (the driver
   starts Chromium on about:blank first and opens the page on "open").
6. Memory: PSS summed over every process the run started (servers, all Chromium processes, binaries; the measurement
   driver itself excluded), every 50 ms from exec to quit; load peak (exec → first dashboard) and steady state
   (measured passes) apart; GPU memory per pid from nvidia-smi (all GPU processes in the tree) once a second outside
   the measured passes (nvidia-smi can stall the GPU: never while a step is timed).
7. Effort counted by this script (lines without blanks/comments, files, languages, build steps; D also the framework
   lines this goal added and the framework's size).
8. results.json + results.md (generated from the JSON), with every caveat.

The driver contract each build documents in its README (docs/goals/38/README.md "Driver contract"): a command that
launches the build in external-drive mode and speaks lines: stdout `ready <json>` (first dashboard drawn; json may hold
`kpi_rect` [x, y, w, h] in window logical pixels and the build's load figures), `shown N <ms> <json>` (after the frame
that shows step N; ms = the build's own change → frame), `error <text>`, `bye`; stdin `step N` (N = 0 … S, the full
state from steps.json), `quit` (write answers.json for every step applied, in order, to --out, close everything).
"""
import argparse
import hashlib
import json
import math
import os
import platform
import re
import signal
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "showcase-data"))
import reference  # noqa: E402
import screen_observer as so  # noqa: E402

OUT = ROOT / "docs/goals/38"
WORK = ROOT / "build/data_bench"  # per-run output (answers.json, browser profiles): not /tmp (RAM-backed here)
W, H = 1280, 800
GAP_MS = 300
SAME_FRAME_MS = 1000 / 60 / 2
CHANGE_TIMEOUT_S = 2.0  # after the build's "shown", the KPI region must change within this
SETTLE_MS = 100  # the KPI region unchanged this long = settled (6 frames at 60 Hz)
WARM, PASSES, RUNS, COLD = 2, 20, 3, 3
PSS_MS = 50
TREE_SCAN_S = 1.0  # the process tree is re-read once a second (new processes join within a second)
GPU_S = 1.0
GATE_STRICT, GATE_LOOSE = 0.5, 2.0
GATE_STRICT_S = 15 * 60  # wait this long for load < 0.5 before accepting < 2 (recorded)
GATE_BUDGET_S = 6 * 3600
GATE_POLL_S = 30
GATE_GPU_UTIL = 5
GATE_IDLE_MIB = 16
STEP_TIMEOUT_S = 120
READY_TIMEOUT_S = 15 * 60  # A's wasm load of 100M took ~56 s; allow for a slow cold cache
CHROMIUM = "/usr/lib/chromium/chromium"
# On Wayland, Chromium refuses Vulkan compositing ("'--ozone-platform=wayland' is not compatible with Vulkan") and its
# window then never updates on screen (tested 2026-10-28 on the headless Hyprland: 1 distinct frame in 1 s with
# --enable-features=Vulkan, 21 without; WebGL is ANGLE on Vulkan on the RTX 3090 either way): the protocol drops that
# one flag, for A and B alike.
CHROMIUM_FLAGS = ["--ozone-platform=wayland", "--use-angle=vulkan", "--ignore-gpu-blocklist"]
PER_RUN_FLAGS = ("--user-data-dir", "--remote-debugging-port", "--app", "--window-size", "--window-position")
PY = sys.executable

BUILDS = {
    # cmd: the driver's command ({rows}, {out}, {python} filled in); driver_is_app: the first process is the app itself
    # (else a measurement driver, left out of the PSS); kpi: the KPI row in window logical pixels when the build's
    # ready JSON doesn't give kpi_rect; compute_keys / load_keys: the build's own figures in its shown / ready JSON.
    "A": {"label": "A · JS + DuckDB-WASM", "web": True, "dir": "showcase-data/js-duckdb",
          "cmd": ["{python}", "showcase-data/js-duckdb/external.py", "--rows", "{rows}", "--out", "{out}"],
          "driver_is_app": False, "kpi": None, "kpi_command": True, "compute_keys": ["query_ms", "compute_ms"],
          "load_keys": ["data_load_ms", "load_ms"],
          "skip": ["check_a.py", "external.py", "package-lock.json"],
          "build_steps": ["pixi install  (Node, esbuild through pixi)", "npm ci --ignore-scripts", "showcase-data/js-duckdb/build.sh",
                          "python showcase-data/js-duckdb/serve.py  (a static server)", "open the page in Chromium"]},
    "B": {"label": "B · JS + FastAPI + Polars", "web": True, "dir": "showcase-data/py-polars",
          "cmd": ["{python}", "showcase-data/py-polars/external.py", "--rows", "{rows}", "--out", "{out}"],
          "driver_is_app": False, "kpi": None, "kpi_command": True, "compute_keys": ["server_compute_ms", "compute_ms"],
          "load_keys": ["data_load_ms", "load_ms"],
          "skip": ["check_b.py", "external.py"],
          "build_steps": ["pixi install  (Python, FastAPI, uvicorn, Polars)", "python showcase-data/py-polars/server.py",
                          "open the page in Chromium"]},
    "C": {"label": "C · Rust + Polars + egui", "web": False, "dir": "showcase-data/rust-polars",
          "cmd": ["showcase-data/rust-polars/target/release/dash", "--scripted-external", "--rows", "{rows}", "--out", "{out}"],
          "driver_is_app": True, "kpi": None, "kpi_command": True, "compute_keys": ["compute_ms"], "load_keys": ["load_ms", "data_load_ms"],
          "skip": ["check_c.py", "Cargo.lock"],
          "build_steps": ["pixi install  (Rust 1.99)", "cargo build --release", "target/release/dash"]},
    "D": {"label": "D · omxcode + omxcore", "web": False, "dir": "examples/dashboard",
          "cmd": ["build/dashboard/linux/dashboard", "--scripted-external", "--rows", "{rows}", "--out", "{out}"],
          "driver_is_app": True, "kpi": None, "kpi_command": False, "compute_keys": ["compute_ms", "gpu_ms"],
          "load_keys": ["data_load_ms", "load_ms"],
          "skip": [],
          "build_steps": ["pixi install  (Mojo 1.1, MAX)", "scripts/build.sh dashboard linux", "build/dashboard/linux/dashboard"]},
}
ORDER = ["A", "B", "C", "D"]
GOAL_BASE = "505e99c"  # "Goal 38 set": D's framework additions are counted from here
FRAMEWORK = ["mojoui"]
D_FRAMEWORK_TESTS = ["tests"]
LANG = {".js": "JavaScript", ".mjs": "JavaScript", ".ts": "TypeScript", ".html": "HTML", ".css": "CSS", ".py": "Python",
        ".rs": "Rust", ".toml": "TOML", ".sh": "Bash", ".mojo": "Mojo", ".json": "JSON"}
SOURCES = ["showcase-data", "examples/dashboard", "mojoui", "scripts/data_bench.py", "scripts/screen_observer.c",
           "scripts/screen_observer.py", "scripts/screen_observer.wlr-screencopy-unstable-v1.xml", "scripts/build.sh"]

CAVEATS = [
    "A runs DuckDB-WASM inside the browser: wasm memory is limited to 4 GB, so 100M rows load compressed (and slowly); "
    "its load time and steps are what that limit allows.",
    "B's every change crosses a network hop (the page's fetch to the local FastAPI server): real, but local (127.0.0.1), "
    "so it is cheaper than any deployed server.",
    "C and D are native desktop programs (native only); A and B are web pages that run in any browser.",
    "D needs an NVIDIA GPU today (CUDA through MAX); Apple through Metal is later work.",
    "D computes on cents: a deliberate data-model choice (amount and cost become integer cents at load, on every core, "
    "counted in its load time; sums are exact integers, converted at the edge); A, B and C keep float64. Every build's "
    "answers match the reference within the SPEC's 1e-6 relative tolerance.",
    "Every build sorts the rows by day at load (SPEC allows reordering at load; the time is in each load figure), so a "
    "date range is a contiguous slice or prunable by zone maps.",
    "Shortcuts each build takes for the newest 50 rows: A stores the table day descending / id ascending so DuckDB's "
    "zone maps prune the date range and its top-N stops after the first row groups, KPIs and chart in one statement; "
    "B takes the date range's slice of its day-descending frame and finds the newest 50 with a hand-written "
    "growing-window search at the slice's start (round 2, as C), the group-by on Polars' streaming engine, orjson; C searches a growing window at the slice's end for the "
    "last 50 matching rows (hand-written, not plain Polars; its README records the plain forms' slower numbers); D "
    "finds the cut-off day from a per-day histogram its GPU group-by already makes (product × day), then the rows on "
    "the GPU. B's and C's searches and D's histogram are equivalent hand-made shortcuts (coordinator, 2026-10-28).",
    "D wakes its UI the moment a background job ends (mojoui.jobs, a framework feature for every app, D-771); the "
    "others redraw when their own event loops see the result.",
    "Chromium's flags for A and B are --ozone-platform=wayland --use-angle=vulkan --ignore-gpu-blocklist: the "
    "protocol's --enable-features=Vulkan was dropped because Chromium can't composite with Vulkan on Wayland (its "
    "window never updated on screen with it); WebGL is ANGLE on Vulkan on the RTX 3090 either way.",
    "Input-to-pixels starts when the harness writes the step to the build's driver: for A and B that adds the driver's "
    "hop into the page (a Chrome DevTools Protocol call, about a millisecond), for C and D a pipe into the app.",
    "The observer sees the compositor's frames (60 Hz here): every latency includes waiting for the next composited "
    "frame (0–16.7 ms) and is reported to the compositor's presentation timestamp, not to the photons.",
    "nvidia-smi is never polled while a step is timed (it can stall the GPU): GPU memory is sampled during load, warm-up "
    "and the untimed resets between passes.",
]


HEADLESS_CAVEAT = ("Measured on a separate headless Hyprland (the owner's session was locked), not the physical monitor: "
                   "output HEADLESS-1 %dx%d @ %s Hz paced by a timer, GPU-rendered (%s, %s through EGL/GBM), no scanout; "
                   "the window and its pixels are real compositor frames, but there is no monitor latency in any number.")


def mono_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


def sh(*cmd, timeout=30, env=None, cwd=ROOT):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd)
        return (r.stdout or r.stderr).strip()
    except Exception as e:  # noqa: BLE001
        return f"({e})"


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while b := f.read(1 << 20):
            h.update(b)
    return h.hexdigest()


def sources_sha():
    """The bytes the measurement depends on: every build's sources, the steps, data.lock, the harness, the observer."""
    files = subprocess.run(["git", "ls-files", *SOURCES], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    h = hashlib.sha256()
    for f in sorted(files):
        p = ROOT / f
        if p.suffix == ".png" or "/out/" in f or not p.is_file():
            continue
        h.update(f.encode() + b"\0" + p.read_bytes() + b"\0")
    return h.hexdigest()


# ---------------------------------------------------------------------------------------------------------------------
# 1. The environment and the quiet gate
# ---------------------------------------------------------------------------------------------------------------------

def environment():
    lock = json.loads((ROOT / "showcase-data/data.lock").read_text())
    pixi = lambda *c: sh("pixi", "run", "--manifest-path", str(ROOT / "pixi.toml"), *c, timeout=120)  # noqa: E731
    cpu = next((l.split(":", 1)[1].strip() for l in sh("lscpu").splitlines() if l.startswith("Model name")), platform.processor())
    gpus = sh("nvidia-smi", "--query-gpu=name,memory.total,pci.bus_id", "--format=csv,noheader")
    dirty = sh("git", "status", "--porcelain", "--", *SOURCES)
    return {
        "cpu": f"{cpu} ({os.cpu_count()} threads)", "memory_gb": round(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30, 1),
        "gpu": gpus, "driver": sh("nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader").splitlines()[0],
        "kernel": platform.release(), "compositor": so.hyprctl("version").splitlines()[0],
        "chromium": sh(CHROMIUM, "--version"), "rust": pixi("rustc", "--version"), "mojo": pixi("mojo", "--version"),
        "polars": pixi("python", "-c", "import polars; print(polars.__version__)"),
        "duckdb": pixi("python", "-c", "import duckdb; print(duckdb.__version__)"),
        "duckdb_wasm": _npm_version("showcase-data/js-duckdb", "@duckdb/duckdb-wasm"),
        "python": platform.python_version(),
        "commit": sh("git", "rev-parse", "HEAD") + (" (sources dirty)" if dirty else ""),
        "data_lock": lock,
    }


def _npm_version(d, pkg):
    p = ROOT / d / "node_modules" / pkg / "package.json"
    return json.loads(p.read_text())["version"] if p.exists() else None


def desktop(headless=None):
    """Where the windows were drawn: the owner's live desktop, or (headless: HeadlessHyprland.record()) a separate
    headless Hyprland on the GPU, which is not the physical monitor."""
    env = so.desktop_env()
    m = so.monitor()
    d = {"wayland_display": env.get("WAYLAND_DISPLAY"), "display": env.get("DISPLAY"),
         "compositor": so.hyprctl("version").splitlines()[0], "headless": bool(headless),
         "monitor": {k: m.get(k) for k in ("name", "description", "width", "height", "refreshRate", "scale", "vrr")},
         "window": [W, H], "window_note": "floated and resized to exactly 1280 × 800 logical pixels, centred, one at a time"}
    if headless:
        d.update({"kind": headless["kind"], "headless_compositor": headless,
                  "note": "the owner's session was locked (travelling), so every window ran on a separate headless "
                          "Hyprland as the same user, GPU-rendered (EGL/GBM) on the RTX 3090 without a monitor; its "
                          "HEADLESS-1 output paces frames at 60 Hz by a timer, with no scanout to a physical monitor"})
    else:
        d["kind"] = "the owner's live Hyprland desktop (D-765)"
    return d


def ancestry_pids():
    """This process and its ancestors (never treated as other GPU users)."""
    out, pid = set(), os.getpid()
    while pid > 1:
        out.add(pid)
        try:
            st = Path(f"/proc/{pid}/stat").read_text()
            pid = int(st[st.rindex(")") + 2:].split()[1])
        except (OSError, ValueError):
            break
    return out


def descendants(root):
    """root and every process below it (by parent pid)."""
    kids = {}
    for p in Path("/proc").iterdir():
        if p.name.isdigit():
            try:
                st = (p / "stat").read_text()
                kids.setdefault(int(st[st.rindex(")") + 2:].split()[1]), []).append(int(p.name))
            except (OSError, ValueError, IndexError):
                pass
    out, todo = [], [root]
    while todo:
        q = todo.pop()
        out.append(q)
        todo += kids.get(q, [])
    return out


NV_PROC = re.compile(r"^\|\s+(\d+)\s+\S+\s+\S+\s+(\d+)\s+(C\+G|C|G)\s+(.+?)\s+(\d+)MiB\s*\|")


def gpu_processes(text=None):
    """Every GPU process nvidia-smi lists (graphics and compute): [(gpu, pid, type, name, MiB)]."""
    if text is None:
        text = sh("nvidia-smi", timeout=20)
    out = []
    for line in text.splitlines():
        m = NV_PROC.match(line)
        if m:
            out.append((int(m.group(1)), int(m.group(2)), m.group(3), m.group(4).strip(), int(m.group(5))))
    return out


def gpu_util():
    try:
        return max(int(x) for x in sh("nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits").split())
    except ValueError:
        return 100


def checks_running():
    """Any scripts/check.py (or scripts/check) running in any worktree, not ours: [(pid, command)]. Read from /proc
    argv elements (the same thing `pgrep -af scripts/check.py` lists, without matching a shell line that merely
    mentions it); this harness never stops them."""
    mine = set(descendants(os.getpid())) | ancestry_pids()
    out = []
    for p in Path("/proc").iterdir():
        if not p.name.isdigit() or int(p.name) in mine:
            continue
        try:
            argv = (p / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if any(a.endswith((b"scripts/check.py", b"scripts/check")) for a in argv):
            out.append((int(p.name), b" ".join(argv).decode(errors="replace")[:160]))
    return out


class NotQuiet(Exception):
    pass


class Gate:
    """Before every run: load < 0.5 (< 2 after GATE_STRICT_S of waiting, recorded), GPU utilisation < 5 %, no other
    GPU process above 16 MiB except the desktop session's graphics clients, and the screen live."""

    def __init__(self, log, desktop_pids):
        self.log, self.waited, self.desktop_pids = log, 0, desktop_pids

    def busy_apps(self, procs, mine):
        return [p for p in procs if p[1] not in mine and p[4] > GATE_IDLE_MIB
                and not (p[2] == "G" and p[1] in self.desktop_pids)]

    def wait(self, what):
        t0, said = time.time(), 0
        while True:
            waited = time.time() - t0
            load, util = os.getloadavg()[0], gpu_util()
            mine = set(descendants(os.getpid())) | ancestry_pids()
            procs = gpu_processes()
            busy = self.busy_apps(procs, mine)
            limit = GATE_STRICT if waited < GATE_STRICT_S else GATE_LOOSE
            checks = checks_running()
            if load < limit and util < GATE_GPU_UTIL and not busy and not checks:
                live = so.screen_live()
                if live is None:
                    self.waited += waited
                    return {"gated": True, "load1": round(load, 2), "load_limit": limit, "gpu_util": util,
                            "waited_s": round(waited), "busy_gpu_apps": [], "checks_running": [],
                            "gpu_processes": [f"{p[1]} {p[2]} {Path(p[3]).name} {p[4]} MiB" for p in procs]}
                why = f"screen not live ({live})"
            else:
                why = (f"load {load:.2f} (< {limit}), GPU {util} %, {len(busy)} other GPU apps, "
                       f"{len(checks)} scripts/check.py running")
            if self.waited + waited > GATE_BUDGET_S:
                raise NotQuiet(f"never quiet before {what}: {why}")
            if time.time() - said > 600 or not said:
                self.log(f"  (waiting before {what}: {why})")
                said = time.time()
            time.sleep(GATE_POLL_S)


def no_gate(log):
    """--provisional: no waiting; the state is still recorded (and the results are marked provisional)."""
    procs = gpu_processes()
    return {"gated": False, "load1": round(os.getloadavg()[0], 2), "gpu_util": gpu_util(), "waited_s": 0,
            "busy_gpu_apps": None, "gpu_processes": [f"{p[1]} {p[2]} {Path(p[3]).name} {p[4]} MiB" for p in procs]}


# ---------------------------------------------------------------------------------------------------------------------
# 6. Memory samplers
# ---------------------------------------------------------------------------------------------------------------------

def _pss_kb(pid):
    try:
        m = re.search(r"^Pss:\s+(\d+) kB", Path(f"/proc/{pid}/smaps_rollup").read_text(), re.M)
        return int(m.group(1)) if m else 0
    except OSError:
        return 0


def _comm(pid):
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return "?"


class Memory:
    """PSS of the run's process tree every 50 ms (the driver left out unless it is the app) and GPU memory per pid once
    a second while `gpu_ok` (outside timed steps). Phases: load (exec → first dashboard), warm, reset, measured."""

    def __init__(self, root, exclude=()):
        self.root, self.exclude = root, set(exclude)
        self.phase, self.gpu_ok = "load", True
        self.pss = {}  # phase -> [MB]
        self.gpu = {}  # phase -> [MiB]
        self.names, self.cost_ms, self.peak_names, self.scan_ms, self.gpus = set(), [], {}, [], set()
        self._stop = threading.Event()
        self._t = [threading.Thread(target=self._pss_loop, daemon=True), threading.Thread(target=self._gpu_loop, daemon=True)]
        for t in self._t:
            t.start()

    def tree(self):
        return [p for p in descendants(self.root) if p not in self.exclude]

    def _pss_loop(self):
        pids, scanned = [], 0.0
        while not self._stop.is_set():
            t0 = time.perf_counter()
            if t0 - scanned >= TREE_SCAN_S:  # a full /proc scan costs ~15 ms here: once a second, PSS reads in between
                pids, scanned = self.tree(), t0
                self.scan_ms.append((time.perf_counter() - t0) * 1000)
            per = {p: _pss_kb(p) for p in pids}
            total = sum(per.values()) / 1024
            ph = self.phase
            self.pss.setdefault(ph, []).append(total)
            if total >= max(self.peak_names.get(ph, (0, None))[0], 0):
                names = {}
                for p, kb in per.items():
                    names[_comm(p)] = names.get(_comm(p), 0) + kb / 1024
                self.peak_names[ph] = (total, {k: round(v, 1) for k, v in sorted(names.items(), key=lambda kv: -kv[1])})
            if t0 == scanned:
                self.names.update(_comm(p) for p in pids)
            self.cost_ms.append((time.perf_counter() - t0) * 1000)
            self._stop.wait(max(0.0, PSS_MS / 1000 - (time.perf_counter() - t0)))

    def _gpu_loop(self):
        while not self._stop.is_set():
            if self.gpu_ok:
                pids = set(self.tree())
                ph = self.phase
                procs = gpu_processes()
                if self.gpu_ok:  # still outside a timed step when nvidia-smi returned
                    self.gpu.setdefault(ph, []).append(sum(p[4] for p in procs if p[1] in pids))
                    self.gpus.update(p[0] for p in procs if p[1] in pids)
            self._stop.wait(GPU_S)

    def stop(self):
        self._stop.set()
        for t in self._t:
            t.join(5)
        steady = self.pss.get("measured", [])
        return {
            "pss_load_peak_mb": round(max(self.pss.get("load", [0])), 1),
            "pss_steady_peak_mb": round(max(steady), 1) if steady else None,
            "pss_steady_median_mb": round(statistics.median(steady), 1) if steady else None,
            "pss_peak_by_process": self.peak_names.get("measured", self.peak_names.get("load", (0, {})))[1],
            "gpu_load_peak_mib": max(self.gpu.get("load", [0])),
            "gpu_steady_peak_mib": max(self.gpu.get("warm", []) + self.gpu.get("reset", []) or [0]),
            "processes": sorted(self.names), "sample_ms": PSS_MS, "gpu_indices": sorted(self.gpus),
            "sampler_cost_ms_median": round(statistics.median(self.cost_ms), 2) if self.cost_ms else None,
            "tree_scan_ms_median": round(statistics.median(self.scan_ms), 2) if self.scan_ms else None,
        }


# ---------------------------------------------------------------------------------------------------------------------
# 2-4. One run of one build
# ---------------------------------------------------------------------------------------------------------------------

def evict(path):
    """Drop the data file's pages from the page cache (unprivileged, posix_fadvise DONTNEED); returns fincore's view."""
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
    finally:
        os.close(fd)
    return cached(path)


def cached(path):
    out = sh("fincore", "--bytes", "--noheadings", "--output", "RES", str(path))
    try:
        return int(out.split()[0])
    except (ValueError, IndexError):
        return None


class BuildError(Exception):
    pass


def ready_json(line):
    """`ready <json>` → the json (or {} for a bare `ready`)."""
    rest = line[len("ready"):].strip()
    return json.loads(rest) if rest.startswith("{") else {}


class Session:
    """One launch of one build in external-drive mode: the driver process, its lines, its window, the observer on the
    KPI region, the memory samplers. Only the processes it starts are ever stopped."""

    def __init__(self, b, rows, out, log, observer=None, place=True, extra_args=(), env=None):
        self.b, self.spec, self.rows, self.out, self.log = b, BUILDS[b], rows, Path(out), log
        self.out.mkdir(parents=True, exist_ok=True)
        self.lines, self._cv = [], threading.Condition()
        self.observer_factory, self.place = observer or so.Observer, place
        self.extra_args, self.env = list(extra_args), env
        self.obs = self.mem = self.win = None
        self.applied = []

    # -- launch --
    def command(self):
        cmd = self.spec["cmd"]
        if not cmd:
            raise BuildError(f"{self.b}: no external-drive command yet (its README's driver contract)")
        return [c.format(python=PY, rows=self.rows, out=str(self.out)) for c in cmd] + self.extra_args

    def environment(self):
        env = dict(self.env) if self.env is not None else so.desktop_env()
        if so.TARGET["headless"]:
            env.pop("DISPLAY", None)  # Wayland only: nothing may reach the owner's X server
            env["GDK_BACKEND"] = "wayland"
        else:
            env.setdefault("DISPLAY", ":0")
        env.update({"DATA_BENCH_CHROMIUM": CHROMIUM, "DATA_BENCH_CHROMIUM_FLAGS": " ".join(CHROMIUM_FLAGS),
                    "MOJOUI_HEADLESS": "0", "PYTHONUNBUFFERED": "1"})
        for k in ("MOJOUI_PRIVATE_DISPLAY", "GSK_RENDERER", "GDK_DISABLE", "GDK_SCALE"):
            env.pop(k, None)
        return env

    def start(self):
        cmd = self.command()
        self.stderr = open(self.out / "driver.stderr", "w")
        self.t_exec = mono_ns()
        self.p = subprocess.Popen(cmd, cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                  text=True, bufsize=1, env=self.environment(), start_new_session=True)
        self.mem = Memory(self.p.pid, exclude=() if self.spec["driver_is_app"] else (self.p.pid,))
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            line = line.rstrip("\n")
            with self._cv:
                self.lines.append((mono_ns(), line))
                self._cv.notify_all()
        with self._cv:
            self.lines.append((mono_ns(), "eof"))
            self._cv.notify_all()

    def expect(self, kind, timeout, arg=None, start=0):
        """The first line of `kind` (and first argument `arg`) at or after index `start`: (index, t_ns, words)."""
        def find():
            for i in range(start, len(self.lines)):
                t, line = self.lines[i]
                w = line.split(" ", 3)
                if w[0] in ("error", "eof"):
                    raise BuildError(f"{self.b}: {line} (stderr: {self.tail()})")
                if w[0] == kind and (arg is None or (len(w) > 1 and w[1] == str(arg))):
                    return i, t, w
            return None
        t_end = time.time() + timeout
        with self._cv:
            while True:
                r = find()
                if r:
                    return r
                left = t_end - time.time()
                if left <= 0:
                    raise BuildError(f"{self.b}: no '{kind}{'' if arg is None else ' ' + str(arg)}' line in {timeout} s (stderr: {self.tail()})")
                self._cv.wait(min(left, 1.0))

    def tail(self):
        try:
            return (self.out / "driver.stderr").read_text()[-600:].replace("\n", " | ")
        except OSError:
            return ""

    def send(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()

    def pids(self):
        return set(descendants(self.p.pid))

    def find_window(self, timeout=READY_TIMEOUT_S):
        t_end = time.time() + timeout
        while time.time() < t_end:
            pids = self.pids()
            for c in so.clients():
                if c.get("pid") in pids and c.get("mapped", True) and c["size"][0] > 0:
                    return c
            if self.p.poll() is not None:
                raise BuildError(f"{self.b}: exited before its window mapped (stderr: {self.tail()})")
            time.sleep(0.02)
        raise BuildError(f"{self.b}: no window in {timeout} s")

    def kpi_rect(self, ready):
        r = (ready or {}).get("kpi_rect") or self.spec.get("kpi")
        if not r:
            raise BuildError(f"{self.b}: no KPI region (ready JSON kpi_rect, or BUILDS['{self.b}']['kpi'] from `calibrate`)")
        return [int(v) for v in r]

    def window_rect(self):
        """Where the window will be: the headless compositor's window rule puts every window at a known rectangle
        (floating, W × H, centred), so the observer can watch it from before the launch."""
        return so.TARGET.get("window_rect")

    def kpi_from_build(self, ready):
        """The KPI row's rect: ask the build (`kpi`, after the window has its final size) when it answers, else the
        ready line's kpi_rect, else BUILDS[b]['kpi'] (from `calibrate`)."""
        if self.spec.get("kpi_command"):
            start = len(self.lines)
            self.send("kpi")
            i, _t, _w = self.expect("kpi", 30, start=start)
            j = json.loads(self.lines[i][1][len("kpi"):].strip() or "null")
            r = j.get("kpi_rect") if isinstance(j, dict) else j
            if r:
                return [round(float(v)) for v in r]
        return self.kpi_rect(ready)

    def open(self, warm_browser=False):
        """Launch with the whole window watched from before exec; first dashboard = the first frame (compositor
        timestamp) whose whole window equals the settled dashboard. Then watch the KPI row and, below it, the chart
        and table. Returns the cold-start record."""
        rect = self.window_rect()
        full = self.observer_factory(*rect) if rect else None
        try:
            self.start()
            rec = {"window_rect": rect}
            if warm_browser:
                self.expect("browser", 120)
            if self.place:
                win = self.find_window()
                rec["window_mapped_ms"] = round((mono_ns() - self.t_exec) / 1e6, 1)
                self.win = so.place(win, W, H)
                if self.win["size"] != [W, H]:
                    raise BuildError(f"{self.b}: the window is {self.win['size']}, not {W}×{H}")
                if rect and self.win["at"] != rect[:2]:
                    raise BuildError(f"{self.b}: the window is at {self.win['at']}, not {rect[:2]}")
            if full is None:  # the owner's desktop: no window rule, watch from the moment it is placed
                ox, oy = self.win["at"] if self.win else (0, 0)
                full = self.observer_factory(ox, oy, W, H)
                rec["cold_note"] = "whole-window observer started after the window was placed (no window rule)"
            if warm_browser:
                self.t_exec = mono_ns()  # without the browser launch: from "open" to the dashboard
                self.send("open")
            i, t_ready, w = self.expect("ready", READY_TIMEOUT_S)
            self.ready = ready_json(self.lines[i][1])
            hf = full.wait_stable(SETTLE_MS * 3, 30)
            first = so.first_match(full.since(self.t_exec), self.t_exec, hf) if hf else None
            rec.update({"first_dashboard_ms": round((first[0] - self.t_exec) / 1e6, 1) if first else None,
                        "first_dashboard_by": "screen: first frame whose whole window equals the settled dashboard",
                        "observer_saw_it_appear": bool(first) and first[0] != full.frames[0][1],
                        "ready_line_ms": round((t_ready - self.t_exec) / 1e6, 1), "ready": self.ready})
            if hf is None:
                rec["first_dashboard_by"] = "none: the window never settled for 300 ms within 30 s"
        finally:
            if full:
                full.close()
        kx, ky, kw, kh = self.kpi = self.kpi_from_build(self.ready)
        ox, oy = self.win["at"] if self.win else (rect[:2] if rect else (0, 0))
        rest_y = ky + kh
        self.rest_rect = [0, rest_y, W, H - rest_y]
        if self.obs is None:
            self.obs = self.observer_factory(ox + kx, oy + ky, kw, kh)
            self.rest = self.observer_factory(ox, oy + rest_y, W, H - rest_y)
        rec["kpi_rect"], rec["rest_rect"] = self.kpi, self.rest_rect
        if self.obs.wait_stable(SETTLE_MS, 30) is None:
            raise BuildError(f"{self.b}: the KPI region never settled after ready")
        self.mem.phase = "warm"
        self.applied = [0]
        return rec

    # -- steps --
    def step(self, n, timed=True):
        """Settle, the 300 ms idle gap, inject step n, wait for its frame. Two regions: the KPI row (the headline)
        and everything below it (chart and table): when both show their settled pictures."""
        if self.obs.wait_stable(SETTLE_MS, 30) is None:
            raise BuildError(f"{self.b}: the KPI region didn't settle before step {n}")
        rest_ok = self.rest.wait_stable(SETTLE_MS, 5) is not None
        prev, prev_rest = self.obs.last()[3], self.rest.last()[3]
        time.sleep(GAP_MS / 1000)
        start = len(self.lines)
        if timed:
            self.mem.gpu_ok = False
        t0 = mono_ns()
        self.send(f"step {n}")
        try:
            i, t_shown, w = self.expect("shown", STEP_TIMEOUT_S, arg=n, start=start)
            # the build's "shown" can come before the compositor presents that frame: wait for the region to change
            # after the injection first (CHANGE_TIMEOUT_S), then for it to settle
            changed = self.obs.wait(lambda fr: any(f[1] >= t0 and f[3] != prev for f in fr[-240:]), CHANGE_TIMEOUT_S)
            final = self.obs.wait_stable(SETTLE_MS, 30, after_ns=t0) if changed else prev
            rest_changed = rest_ok and self.rest.wait(lambda fr: any(f[1] >= t0 and f[3] != prev_rest for f in fr[-240:]), 1.0)
            final_rest = self.rest.wait_stable(SETTLE_MS, 5, after_ns=t0) if rest_changed else None
        finally:
            self.mem.gpu_ok = True
        self.applied.append(n)
        if final is None:
            raise BuildError(f"{self.b}: the KPI region never settled after step {n}")
        if final == prev and n != 0:
            raise BuildError(f"{self.b}: step {n}'s KPI region didn't change within {CHANGE_TIMEOUT_S} s of '{' '.join(w[:3])}'")
        fr = self.obs.since(t0)
        hit = so.first_match(fr, t0, final)
        change = next((f for f in fr if f[3] != prev), None)
        rest_hit = so.first_match(self.rest.since(t0), t0, final_rest) if final_rest and final_rest != prev_rest else None
        in_app = float(w[2]) if len(w) > 2 else None
        extra = json.loads(w[3]) if len(w) > 3 and w[3].startswith("{") else {}
        lat = round((hit[0] - t0) / 1e6, 3) if hit and final != prev else None
        rest_ms = round((rest_hit[0] - t0) / 1e6, 3) if rest_hit else None
        return {"step": n, "visible_change": final != prev, "latency_ms": lat,
                "receipt_ms": round((hit[1] - t0) / 1e6, 3) if hit else None,
                "first_change_ms": round((change[1] - t0) / 1e6, 3) if change else None,
                "chart_table_ms": rest_ms, "all_ms": max(lat, rest_ms) if lat is not None and rest_ms is not None else None,
                # two observers copy one compositor frame at slightly different moments (~1–2 ms apart): within half a
                # frame (8.3 ms at 60 Hz) is the same composited frame
                "same_frame": (abs(lat - rest_ms) < SAME_FRAME_MS) if lat is not None and rest_ms is not None else None,
                "rest_settled": final_rest is not None,
                "shown_line_ms": round((t_shown - t0) / 1e6, 3), "in_app_ms": in_app, "build": extra}

    def visible(self):
        return self.win is None or so.visible(self.win)

    # -- close --
    def close(self):
        """quit → answers.json; then stop only what this session started (its process group, then any straggler from
        its tree)."""
        answers = None
        tree = set()
        try:
            tree = self.pids()
            if self.p.poll() is None:
                start = len(self.lines)
                self.send("quit")
                try:
                    self.expect("bye", 120, start=start)
                except BuildError:
                    pass
            p = self.out / "answers.json"
            if p.exists():
                answers = json.loads(p.read_text())
        finally:
            mem = self.mem.stop() if self.mem else None
            for o in (self.obs, getattr(self, "rest", None)):
                if o:
                    o.close()
            try:
                self.p.wait(15)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.p.pid, signal.SIGTERM)
                    self.p.wait(10)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    try:
                        os.killpg(self.p.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            for pid in tree - {self.p.pid}:  # stragglers from this session's own tree (e.g. a setsid'd browser)
                try:
                    os.kill(pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
            self.stderr.close()
        return answers, mem


def chromium_argv(pids):
    """The browser process's command line (Chromium without --type=), per-run arguments dropped."""
    for pid in sorted(pids):
        try:
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().decode().split("\0")
        except OSError:
            continue
        if argv and argv[0].endswith("chromium") and not any(a.startswith("--type=") for a in argv):
            return [a for a in argv if a and not a.startswith(PER_RUN_FLAGS)]
    return None


def check_answers(answers, applied, rows, passes):
    """reference.compare on every pass: the opening state before it (step 0) + its steps 1…S. Returns
    (passes_checked, problems)."""
    want = reference.expected(rows)
    S = len(reference.states()) - 1
    got = (answers or {}).get("steps") or []
    if [a.get("step") for a in got] != applied:
        return 0, [f"answers.json lists steps {[a.get('step') for a in got][:12]}…, the harness applied {applied[:12]}…"]
    problems, checked, i = [], 0, 0
    for p in range(passes):
        if applied[i] != 0 or applied[i + 1:i + 1 + S] != list(range(1, S + 1)):
            return checked, problems + [f"pass {p + 1}: not step 0 then 1…{S}"]
        one = {"steps": [got[i], *got[i + 1:i + 1 + S]]}
        problems += [f"pass {p + 1}: {x}" for x in reference.compare(one, want)]
        checked += 1
        i += 1 + S
    return checked, problems


def one_run(b, rows, run, log, gate, passes=PASSES, warm=WARM, observer=None, place=True, env=None):
    """Launch fresh, first dashboard, WARM + PASSES passes of steps 1…S with step 0 between them; correctness on
    every pass. Returns the run's record (void with the reason on any failure)."""
    S = len(reference.states()) - 1
    out = WORK / f"{b}-{rows}-run{run}"
    rec = {"run": run, "gate": gate, "warmup_passes": warm, "measured_passes": passes, "gap_ms": GAP_MS,
           "settle_ms": SETTLE_MS, "window": [W, H], "fresh_launch": True, "page_cache": None}
    data = ROOT / "data" / f"orders-{rows}.parquet"
    rec["page_cache"] = f"warm: {cached(data)} of {data.stat().st_size} bytes of the data file cached at launch" if data.exists() else None
    s = Session(b, rows, out, log, observer=observer, place=place, env=env)
    lat, inapp, first_change, receipt, build, rest, allv, same = {}, {}, {}, {}, {}, {}, {}, {}
    answers = mem = None
    try:
        rec["cold_warm_cache"] = s.open()
        if BUILDS[b]["web"]:
            rec["chromium_argv"] = chromium_argv(s.pids())
        for p in range(warm + passes):
            measured = p >= warm
            if p:
                s.mem.phase = "reset"
                s.step(0, timed=False)
            if not s.visible():
                raise BuildError(f"{b}: its window left the visible workspace")
            s.mem.phase = "measured" if measured else "warm"
            for n in range(1, S + 1):
                r = s.step(n, timed=True)
                if not measured:
                    continue
                if not r["visible_change"]:
                    raise BuildError(f"{b}: step {n} didn't change the KPI region (is kpi_rect right?)")
                k = str(n)
                lat.setdefault(k, []).append(r["latency_ms"])
                inapp.setdefault(k, []).append(r["in_app_ms"])
                first_change.setdefault(k, []).append(r["first_change_ms"])
                receipt.setdefault(k, []).append(r["receipt_ms"])
                build.setdefault(k, []).append(r["build"])
                rest.setdefault(k, []).append(r["chart_table_ms"])
                allv.setdefault(k, []).append(r["all_ms"])
                same.setdefault(k, []).append(r["same_frame"])
            log(f"    {b} run {run} pass {p + 1}/{warm + passes}{'' if measured else ' (warm-up)'}: "
                f"median {statistics.median([v[-1] for v in lat.values()]) if measured else 0:.1f} ms")
        s.mem.phase = "done"
    except (BuildError, so.ScreenNotLive, RuntimeError, OSError) as e:
        rec["void"] = str(e)
        log(f"    {b} run {run} VOID: {e}")
    finally:
        answers, mem = s.close()
    rec["memory"] = mem
    if not rec.get("void"):
        checked, problems = check_answers(answers, s.applied, rows, warm + passes)
        rec["correctness"] = {"passes_checked": checked, "problems": problems[:20]}
        if problems or checked != warm + passes:
            rec["void"] = f"correctness: {problems[:3] or 'not every pass checked'}"
    rec.update({"latency_ms": lat, "in_app_ms": inapp, "first_change_ms": first_change, "receipt_ms": receipt,
                "chart_table_ms": rest, "all_ms": allv, "same_frame": same,
                "build_figures": build, "applied": len(s.applied)})
    return rec


def cold_runs(b, rows, n, log, gate_fn, warm_browser=False, observer=None, place=True, env=None):
    """n cold starts with the data file evicted from the page cache: exec → first dashboard on screen."""
    data = ROOT / "data" / f"orders-{rows}.parquet"
    out = []
    for k in range(n):
        g = gate_fn(f"{b} cold {k + 1}")
        left = evict(data) if data.exists() else None
        s = Session(b, rows, WORK / f"{b}-{rows}-cold{k}{'-warmbrowser' if warm_browser else ''}", log,
                    observer=observer, place=place, env=env, extra_args=["--warm-browser"] if warm_browser else [])
        rec = {"gate": g, "page_cache": f"data file evicted (posix_fadvise DONTNEED): {left} bytes left cached; "
                                        "executables and libraries warm"}
        try:
            rec.update(s.open(warm_browser=warm_browser))
        except (BuildError, so.ScreenNotLive, RuntimeError, OSError) as e:
            rec["void"] = str(e)
            log(f"    {b} cold {k + 1} VOID: {e}")
        finally:
            _answers, mem = s.close()
        rec["memory"] = mem
        out.append(rec)
        log(f"    {b} cold {k + 1}{' (browser already running)' if warm_browser else ''}: "
            f"{rec.get('first_dashboard_ms')} ms to the first dashboard")
    return out


# ---------------------------------------------------------------------------------------------------------------------
# Summaries
# ---------------------------------------------------------------------------------------------------------------------

def pct(xs, q):
    """The q-quantile, nearest rank (p95 of 20 values is the 19th)."""
    xs = sorted(x for x in xs if x is not None)
    return xs[max(0, math.ceil(q * len(xs)) - 1)] if xs else None


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def r3(x):
    return None if x is None else round(x, 3)


def summarise(b, runs, colds, colds_warm_browser):
    S = len(reference.states()) - 1
    ok = [r for r in runs if not r.get("void")]
    per_step, pooled, pooled_app = {}, [], []
    for n in range(1, S + 1):
        k = str(n)
        xs = [x for r in ok for x in r["latency_ms"].get(k, [])]
        ys = [y for r in ok for y in r["in_app_ms"].get(k, [])]
        fc = [y for r in ok for y in r["first_change_ms"].get(k, [])]
        al = [y for r in ok for y in r.get("all_ms", {}).get(k, [])]
        sf = [y for r in ok for y in r.get("same_frame", {}).get(k, []) if y is not None]
        pooled += xs
        pooled_app += ys
        per_step[k] = {"median_ms": r3(med(xs)), "p95_ms": r3(pct(xs, 0.95)), "worst_ms": r3(max(xs) if xs else None),
                       "in_app_median_ms": r3(med(ys)), "first_change_median_ms": r3(med(fc)),
                       "all_median_ms": r3(med(al)), "all_p95_ms": r3(pct(al, 0.95)),
                       "same_frame_share": round(sum(sf) / len(sf), 3) if sf else None,
                       "run_medians_ms": [r3(med(r["latency_ms"].get(k, []))) for r in ok]}
    out = {"label": BUILDS[b]["label"], "runs": runs, "per_step": per_step}
    if ok:
        mom = med([v["median_ms"] for v in per_step.values()])
        run_mom = [med([med(r["latency_ms"][str(n)]) for n in range(1, S + 1)]) for r in ok]
        out["summary"] = {
            "median_of_medians_ms": r3(mom), "pooled_p95_ms": r3(pct(pooled, 0.95)), "worst_ms": r3(max(pooled)),
            "in_app_median_of_medians_ms": r3(med([v["in_app_median_ms"] for v in per_step.values()])),
            "in_app_pooled_p95_ms": r3(pct(pooled_app, 0.95)),
            "gap_observed_minus_in_app_ms": r3(med([a - b_ for r in ok for k in r["latency_ms"]
                                                    for a, b_ in zip(r["latency_ms"][k], r["in_app_ms"][k]) if a is not None and b_ is not None])),
            "run_medians_of_medians_ms": [r3(x) for x in run_mom], "samples": len(pooled),
            "all_median_of_medians_ms": r3(med([v["all_median_ms"] for v in per_step.values()])),
            "all_pooled_p95_ms": r3(pct([y for r in ok for v in r.get("all_ms", {}).values() for y in v], 0.95)),
            "same_frame_share": r3(med([v["same_frame_share"] for v in per_step.values()]))}
        comp = {}
        for key in BUILDS[b]["compute_keys"]:
            vals = {k: [f.get(key) for r in ok for f in r["build_figures"].get(k, []) if isinstance(f.get(key), (int, float))]
                    for k in per_step}
            if all(vals.values()):
                comp = {"key": key, "median_of_medians_ms": r3(med([med(v) for v in vals.values()])),
                        "pooled_p95_ms": r3(pct([x for v in vals.values() for x in v], 0.95)),
                        "per_step_median_ms": {k: r3(med(v)) for k, v in vals.items()}}
                break
        if comp:
            out["compute_ms"] = comp
        else:
            out["compute_not_separable"] = f"the build's shown lines carry none of {BUILDS[b]['compute_keys']}"
    cold = {}
    good = [c for c in colds if not c.get("void") and c.get("first_dashboard_ms") is not None]
    variant = "with_browser" if BUILDS[b]["web"] else "process"
    cold[variant] = {"runs_ms": [c["first_dashboard_ms"] for c in good], "median_ms": r3(med([c["first_dashboard_ms"] for c in good])),
                     "page_cache": good[0]["page_cache"] if good else None, "void": [c["void"] for c in colds if c.get("void")]}
    if BUILDS[b]["web"]:
        gw = [c for c in colds_warm_browser if not c.get("void") and c.get("first_dashboard_ms") is not None]
        cold["without_browser"] = {"runs_ms": [c["first_dashboard_ms"] for c in gw], "median_ms": r3(med([c["first_dashboard_ms"] for c in gw])),
                                   "page_cache": gw[0]["page_cache"] if gw else None,
                                   "void": [c["void"] for c in colds_warm_browser if c.get("void")]}
    loads = [_first_key(c.get("ready") or {}, BUILDS[b]["load_keys"]) for c in good]
    loads = [x for x in loads if x is not None]
    if good:
        cold["split"] = {"process_start_ms": r3(med([c.get("window_mapped_ms") for c in good])),
                         "data_load_ms": r3(med(loads)),
                         "first_frame_ms": r3(med([c["first_dashboard_ms"] - (_first_key(c.get("ready") or {}, BUILDS[b]["load_keys"]) or 0)
                                                   - (c.get("window_mapped_ms") or 0) for c in good])),
                         "note": "process start = exec → window mapped; data load = the build's own figure; first frame = the rest"}
    out["cold"] = cold
    out["data_load_ms"] = r3(med(loads))
    mems = [r["memory"] for r in runs + colds if r.get("memory")]
    if mems:
        out["memory"] = {
            "pss_load_peak_mb": max(m["pss_load_peak_mb"] for m in mems),
            "pss_steady_peak_mb": max((m["pss_steady_peak_mb"] or 0) for m in mems) or None,
            "pss_steady_median_mb": med([m["pss_steady_median_mb"] for m in mems]),
            "gpu_peak_mib": max(max(m["gpu_load_peak_mib"], m["gpu_steady_peak_mib"]) for m in mems),
            "gpu_load_peak_mib": max(m["gpu_load_peak_mib"] for m in mems),
            "gpu_steady_peak_mib": max(m["gpu_steady_peak_mib"] for m in mems),
            "processes": sorted({p for m in mems for p in m["processes"]}), "sample_ms": PSS_MS,
            "gpu_indices": sorted({g for m in mems for g in m.get("gpu_indices", [])}),
            "pss_peak_by_process": next((m["pss_peak_by_process"] for m in mems if m["pss_steady_peak_mb"]), mems[0]["pss_peak_by_process"]),
            "sampler_cost_ms_median": med([m["sampler_cost_ms_median"] for m in mems])}
    return out


def _first_key(d, keys):
    for k in keys:
        if isinstance(d.get(k), (int, float)):
            return d[k]
        for v in d.values():
            if isinstance(v, dict) and isinstance(v.get(k), (int, float)):
                return v[k]
    return None


# ---------------------------------------------------------------------------------------------------------------------
# 7. Effort, counted
# ---------------------------------------------------------------------------------------------------------------------

def code_lines(path):
    """Lines that aren't blank or only a comment (//, /* */, #, <!-- -->, Python/Mojo docstrings)."""
    import particles_bench
    return particles_bench.code_lines(path)


def build_files(b):
    spec = BUILDS[b]
    files = subprocess.run(["git", "ls-files", spec["dir"]], cwd=ROOT, capture_output=True, text=True).stdout.split()
    keep = []
    for f in files:
        p = Path(f)
        if p.name in spec["skip"] or p.suffix not in LANG or any(x in p.parts for x in ("out", "dist", "target", "node_modules", "shots")):
            continue
        if p.suffix == ".json" and p.name != "package.json":
            continue
        keep.append(ROOT / f)
    return keep


def framework_added():
    """Lines (not blank, not only a comment) this goal added to the framework and its tests, per file, from git
    (committed and uncommitted, new files included)."""
    diff = subprocess.run(["git", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", "--unified=0",
                           GOAL_BASE, "--", *FRAMEWORK, *D_FRAMEWORK_TESTS], cwd=ROOT, capture_output=True, text=True).stdout
    per, cur = {}, None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            cur = line[6:] if line.startswith("+++ b/") else None
        elif cur and line.startswith("+") and not line.startswith("+++"):
            t = line[1:].strip()
            if t and not t.startswith("#") and not t.startswith('"""'):
                per[cur] = per.get(cur, 0) + 1
    new = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", *FRAMEWORK, *D_FRAMEWORK_TESTS], cwd=ROOT,
                         capture_output=True, text=True).stdout.split()
    for f in new:
        if Path(f).suffix == ".mojo":
            per[f] = code_lines(ROOT / f)
    return per


def effort():
    out = {}
    for b in ORDER:
        files = build_files(b)
        langs = sorted({LANG[f.suffix] for f in files} - {"JSON", "TOML"})
        out[b] = {"files": len(files), "lines": sum(code_lines(f) for f in files),
                  "by_file": {str(f.relative_to(ROOT)): code_lines(f) for f in files},
                  "languages": langs, "build_steps": len(BUILDS[b]["build_steps"]), "steps": BUILDS[b]["build_steps"]}
    fw = framework_added()
    size = subprocess.run(["git", "ls-files", *FRAMEWORK], cwd=ROOT, capture_output=True, text=True).stdout.split()
    out["D"]["framework_added"] = {"lines": sum(fw.values()), "by_file": fw, "since": GOAL_BASE}
    out["D"]["framework"] = {"lines": sum(code_lines(ROOT / f) for f in size if f.endswith(".mojo")),
                             "files": sum(1 for f in size if f.endswith(".mojo")), "dirs": FRAMEWORK,
                             "note": "mojoui's Mojo files (MX frame, vendored under vendor/, not counted)"}
    return out


# ---------------------------------------------------------------------------------------------------------------------
# The whole measurement
# ---------------------------------------------------------------------------------------------------------------------

def plan(builds=ORDER, runs=RUNS, passes=PASSES, cold=COLD):
    """The schedule and an estimate of its length from each build's own earlier --bench figures (or a guess)."""
    S = len(reference.states()) - 1
    est = {"A": (0.15, 60), "B": (0.08, 15), "C": (0.05, 7), "D": (0.02, 10)}  # (per step s, cold start s) at 100M
    rounds = [builds[r % len(builds):] + builds[:r % len(builds)] for r in range(runs)]
    lines, total = [], 0.0
    for r, order in enumerate(rounds):
        for b in order:
            step_s, cold_s = est[b]
            t = cold_s + 3 + (WARM + passes) * S * (step_s + (GAP_MS + SETTLE_MS) / 1000 + 0.02) + (WARM + passes - 1) * (step_s + 0.45) + 5
            total += t
            lines.append(f"  round {r + 1}: {b}  ~{t / 60:.1f} min  (launch, {WARM} warm-up + {passes} measured passes × {S} steps)")
    for b in builds:
        step_s, cold_s = est[b]
        for variant in (["with browser", "without browser"] if BUILDS[b]["web"] else ["process"]):
            t = cold * (cold_s + 10)
            total += t
            lines.append(f"  cold: {b} {variant}  {cold} × ~{cold_s + 10:.0f} s  (data file evicted)")
    total += 60 + 30 * runs * len(builds) / 60  # selftest + gates when quiet
    return lines, total


def hold_until(a, log):
    """--start-after HH:MM: don't start before then, and then wait until the machine has been busy (a scheduled job
    started: 1-minute load ≥ 4) and quiet again, or --busy-wait-s passed without it getting busy."""
    if not a.start_after:
        return
    hh, mm = (int(x) for x in a.start_after.split(":"))
    now = time.localtime()
    target = time.mktime((now.tm_year, now.tm_mon, now.tm_mday, hh, mm, 0, 0, 0, -1))
    if target < time.time() - 12 * 3600:
        target += 86400
    if time.time() < target:
        log(f"holding until {a.start_after} (the scheduled regression)")
        while time.time() < target:
            time.sleep(30)
    if a.busy_wait_s <= 0:
        log(f"  {a.start_after} reached; the quiet gate takes it from here")
        return
    t0, busy = time.time(), False
    while time.time() - t0 < a.busy_wait_s:
        if os.getloadavg()[0] >= 4:
            busy = True
            break
        time.sleep(30)
    log(f"  the machine {'got busy' if busy else 'stayed quiet'} after {a.start_after}; the quiet gate takes it from here")


def run_all(a, log):
    hold_until(a, log)
    comp = None
    if a.display == "headless":
        comp = so.HeadlessHyprland()
        rec = comp.start()
        log(f"headless Hyprland: {rec['wayland_display']}, {rec['output']}, {rec.get('renderer')} ({rec.get('render_node')})")
    try:
        return _run_all(a, log, rec if comp else None)
    finally:
        if comp:
            comp.stop()


def _run_all(a, log, headless):
    env = environment()
    desk = desktop(headless)
    log(f"env: {env['cpu']}; {env['gpu'].splitlines()[0]}; driver {env['driver']}; {env['compositor']}; {env['commit']}")
    desktop_pids = {p[1] for p in gpu_processes() if p[2] == "G"}
    gate = (lambda what: no_gate(log)) if a.provisional else Gate(log, desktop_pids).wait
    log("observer self-test (probe window on the desktop) …")
    g0 = gate("the observer self-test")
    st = so.selftest(write=True)
    obs = {"method": st["method"], "selftest": st, "gate": g0,
           "region_note": "the KPI row only (a ~2048 × 200 px copy per composited frame at the monitor's 1.6 scale)"}
    log(f"  observer: timestamp − presented median {st['observer_timestamp_minus_presented_ms']}, receipt {st['observer_receipt_minus_presented_ms']}, missed {st['missed']}")
    builds = a.builds
    runs = {b: [] for b in builds}
    for r in range(a.runs):
        order = builds[r % len(builds):] + builds[:r % len(builds)]
        for b in order:
            g = gate(f"{b} run {r + 1}")
            log(f"  {b} run {r + 1} (load {g['load1']}, GPU {g['gpu_util']} %)")
            runs[b].append(one_run(b, a.rows, r + 1, log, g, passes=a.passes))
    colds, colds_wb = {b: [] for b in builds}, {b: [] for b in builds}
    for b in builds:
        colds[b] = cold_runs(b, a.rows, a.cold, log, gate)
        if BUILDS[b]["web"]:
            colds_wb[b] = cold_runs(b, a.rows, a.cold, log, gate, warm_browser=True)
    eff = effort()
    res = {"script": "scripts/data_bench.py", "provisional": bool(a.provisional), "rows": a.rows,
           "measured_at": time.strftime("%Y-%m-%d %H:%M:%S"), "sources_sha256": sources_sha(),
           "fairness_sha256": sha256_file(OUT / "fairness.md") if (OUT / "fairness.md").exists() else None,
           "environment": env, "desktop": desk, "observer": obs,
           "protocol": {"window": [W, H], "gap_ms": GAP_MS, "settle_ms": SETTLE_MS, "warmup_passes": WARM, "measured_passes": a.passes,
                        "runs": a.runs, "cold_runs": a.cold, "pss_sample_ms": PSS_MS, "gpu_sample_s": GPU_S,
                        "order": [builds[r % len(builds):] + builds[:r % len(builds)] for r in range(a.runs)],
                        "chromium": [CHROMIUM, *CHROMIUM_FLAGS]},
           "chromium": {}, "builds": {}, "caveats": list(CAVEATS)}
    for b in builds:
        res["builds"][b] = summarise(b, runs[b], colds[b], colds_wb[b])
        res["builds"][b]["effort"] = eff[b]
        argv = next((r.get("chromium_argv") for r in runs[b] if r.get("chromium_argv")), None)
        if BUILDS[b]["web"]:
            res["chromium"][b] = argv
    if headless:
        res["caveats"].insert(0, HEADLESS_CAVEAT % (headless["output"]["width"], headless["output"]["height"],
                                                    headless["output"]["refreshRate"], headless.get("renderer"), headless["drm_device"]))
    res["caveats"] += data_caveats(res)
    return res


def data_caveats(res):
    out = []
    for b, r in res["builds"].items():
        c = r.get("cold") or {}
        for v in ("process", "with_browser", "without_browser"):
            if v in c and c[v].get("page_cache"):
                out.append(f"{b} cold start ({v.replace('_', ' ')}): {c[v]['page_cache']}")
        warm = {x.get("page_cache") for x in r["runs"] if x.get("page_cache")}
        if warm:
            out.append(f"{b} measured runs launched with the page cache warm: {'; '.join(sorted(warm))}")
        void = [x["void"] for x in r["runs"] if x.get("void")]
        if void:
            out.append(f"{b}: {len(void)} run(s) voided and not counted: {void[:2]}")
        if any(c.get("observer_saw_it_appear") is False for x in r["runs"] for c in [x.get("cold_warm_cache") or {}]):
            out.append(f"{b}: in some runs the first dashboard was drawn before the observer started (cold start is an upper bound there)")
    return out


# ---------------------------------------------------------------------------------------------------------------------
# 8. The report (generated from results.json only)
# ---------------------------------------------------------------------------------------------------------------------

def f1(x, d=1):
    return "–" if x is None else f"{x:,.{d}f}"


def report(res):
    B = res["builds"]
    bs = [b for b in ORDER if b in B]
    L = [f"# Goal 38 M5: the measure{' (PROVISIONAL)' if res.get('provisional') else ''}", "",
         f"Generated by scripts/data_bench.py from results.json ({res['measured_at']}, {res['rows']} rows, "
         f"commit {res['environment']['commit'][:12]}). Do not edit by hand.", "",
         "## Input-to-pixels per change (ms, the external observer)", "",
         "| Build | median of medians | pooled p95 | worst | in-app median | observed − in-app | first visible change | "
         "KPIs + chart + table: median / p95 | same frame | runs (median each) |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    for b in bs:
        r = B[b]
        if r.get("does_not_load"):
            L.append(f"| {r['label']} | does not load: {r['does_not_load'].get('error')} | | | | | | | | |")
            continue
        s = r.get("summary") or {}
        fc = med([v.get("first_change_median_ms") for v in r["per_step"].values()])
        same = "–" if s.get("same_frame_share") is None else f"{100 * s['same_frame_share']:.0f} %"
        L.append(f"| {r['label']} | {f1(s.get('median_of_medians_ms'))} | {f1(s.get('pooled_p95_ms'))} | {f1(s.get('worst_ms'))} | "
                 f"{f1(s.get('in_app_median_of_medians_ms'))} | {f1(s.get('gap_observed_minus_in_app_ms'))} | {f1(fc)} | "
                 f"{f1(s.get('all_median_of_medians_ms'))} / {f1(s.get('all_pooled_p95_ms'))} | "
                 f"{same} | "
                 f"{', '.join(f1(x) for x in s.get('run_medians_of_medians_ms', []))} |")
    L += ["", "## Per step (median / p95 / worst, ms)", "", "| Step | change | " + " | ".join(bs) + " |", "|---|---|" + "---|" * len(bs)]
    states = reference.states()
    for n in range(1, len(states)):
        k = str(n)
        cells = []
        for b in bs:
            v = B[b].get("per_step", {}).get(k) or {}
            cells.append(f"{f1(v.get('median_ms'))} / {f1(v.get('p95_ms'))} / {f1(v.get('worst_ms'))}")
        L.append(f"| {n} | {states[n]['change']} | " + " | ".join(cells) + " |")
    L += ["", "## Compute (the build's own figure, where separable)", "", "| Build | figure | median of medians | pooled p95 |", "|---|---|---|---|"]
    for b in bs:
        c = B[b].get("compute_ms")
        L.append(f"| {B[b]['label']} | {c['key']} | {f1(c['median_of_medians_ms'])} | {f1(c['pooled_p95_ms'])} |" if c
                 else f"| {B[b]['label']} | not separable: {B[b].get('compute_not_separable', '–')} | | |")
    L += ["", "## Cold start to the first dashboard on screen (ms; data file evicted from the page cache)", "",
          "| Build | variant | runs | median | process start | data load | first frame |", "|---|---|---|---|---|---|---|"]
    for b in bs:
        c = B[b].get("cold") or {}
        sp = c.get("split") or {}
        for v in ("process", "with_browser", "without_browser"):
            if v in c:
                L.append(f"| {B[b]['label']} | {v.replace('_', ' ')} | {', '.join(f1(x, 0) for x in c[v]['runs_ms'])} | {f1(c[v]['median_ms'], 0)} | "
                         f"{f1(sp.get('process_start_ms'), 0) if v != 'without_browser' else '–'} | {f1(sp.get('data_load_ms'), 0)} | "
                         f"{f1(sp.get('first_frame_ms'), 0) if v != 'without_browser' else '–'} |")
    L += ["", "## Memory", "", "| Build | PSS load peak (MB) | PSS steady peak (MB) | PSS steady median (MB) | GPU peak (MiB) | GPU load / steady (MiB) | processes |",
          "|---|---|---|---|---|---|---|"]
    for b in bs:
        m = B[b].get("memory") or {}
        L.append(f"| {B[b]['label']} | {f1(m.get('pss_load_peak_mb'), 0)} | {f1(m.get('pss_steady_peak_mb'), 0)} | {f1(m.get('pss_steady_median_mb'), 0)} | "
                 f"{f1(m.get('gpu_peak_mib'), 0)} | {f1(m.get('gpu_load_peak_mib'), 0)} / {f1(m.get('gpu_steady_peak_mib'), 0)} | "
                 f"{', '.join(m.get('processes', []))} |")
    L += ["", "## Effort (counted by the script)", "", "| Build | lines | files | languages | build steps |", "|---|---|---|---|---|"]
    for b in bs:
        e = B[b].get("effort") or {}
        L.append(f"| {B[b]['label']} | {e.get('lines')} | {e.get('files')} | {', '.join(e.get('languages', []))} | {e.get('build_steps')} |")
    e = (B.get("D") or {}).get("effort") or {}
    if e.get("framework_added"):
        L.append("")
        L.append(f"D also added {e['framework_added']['lines']} lines to the framework this goal (since {e['framework_added']['since']}: "
                 f"{', '.join(f'{k} {v}' for k, v in e['framework_added']['by_file'].items())}); the framework is "
                 f"{e['framework']['lines']} lines in {e['framework']['files']} files.")
    env, d, o = res["environment"], res["desktop"], res["observer"]
    st = o["selftest"]
    L += ["", "## Setup", "",
          f"- Display: {d.get('kind')}" + (f" ({d['headless_compositor'].get('renderer')}, {d['headless_compositor'].get('render_node')}, "
                                             f"output {d['monitor'].get('name')} {d['monitor'].get('width')}×{d['monitor'].get('height')} @ {d['monitor'].get('refreshRate')} Hz)"
                                             if d.get("headless") else ""),
          f"- CPU {env['cpu']}, {env.get('memory_gb')} GB; GPU {env['gpu'].replace(chr(10), '; ')}; driver {env['driver']}; kernel {env['kernel']}",
          f"- {d['compositor']}; monitor {d['monitor'].get('name')} {d['monitor'].get('width')}×{d['monitor'].get('height')} @ "
          f"{d['monitor'].get('refreshRate')} Hz, scale {d['monitor'].get('scale')}; window {W}×{H} logical",
          f"- {env['chromium']} ({' '.join(res['protocol']['chromium'][1:])}); Rust {env['rust']}; Mojo {env['mojo']}; Polars "
          f"{env['polars']}; DuckDB {env['duckdb']}; DuckDB-WASM {env.get('duckdb_wasm')}",
          f"- data.lock: 100M {env['data_lock']['files']['orders-100M.parquet']['sha256'][:16]}…, 10M "
          f"{env['data_lock']['files']['orders-10M.parquet']['sha256'][:16]}…; commit {env['commit']}",
          f"- Protocol: {res['protocol']['runs']} runs per build interleaved {', '.join(''.join(o_) for o_ in res['protocol']['order'])}; "
          f"{res['protocol']['warmup_passes']} warm-up + {res['protocol']['measured_passes']} measured passes of every step; {GAP_MS} ms idle "
          f"before each step; correctness checked on every pass",
          f"- Observer: {o['method']}; its timestamp − the compositor's presented time: median "
          f"{(st.get('observer_timestamp_minus_presented_ms') or {}).get('median')} ms; delivery after presentation: median "
          f"{(st.get('observer_receipt_minus_presented_ms') or {}).get('median')} ms; frames every "
          f"{(st.get('observer_frame_interval_ms_under_continuous_change') or {}).get('median')} ms under continuous change; "
          f"{st.get('missed')} of {st.get('flips')} probe changes missed",
          "", "## Caveats", ""]
    L += [f"- {c}" for c in res["caveats"]]
    return "\n".join(L) + "\n"


def write(res):
    OUT.mkdir(parents=True, exist_ok=True)
    name = ("results" if res["rows"] == "100M" else f"results-{res['rows']}") + ("-provisional" if res.get("provisional") else "")
    (OUT / f"{name}.json").write_text(json.dumps(res, indent=1) + "\n")
    (OUT / f"{name}.md").write_text(report(res))
    return OUT / f"{name}.json"


# ---------------------------------------------------------------------------------------------------------------------
# calibrate: one build, its window and the KPI region, as pictures
# ---------------------------------------------------------------------------------------------------------------------

def calibrate(b, rows, log, display="headless"):
    comp = so.HeadlessHyprland() if display == "headless" else None
    if comp:
        comp.start()
    try:
        _calibrate(b, rows, log)
    finally:
        if comp:
            comp.stop()


def _calibrate(b, rows, log):
    """Launch b, watch its whole window from before exec, and save it (PNG) at the opening state, after step 1 and
    after step 0 again, with the KPI rect the build reports drawn as a list; record whether the KPI row, chart and
    table change in the same frame (calibrate.json). Closes everything."""
    out = WORK / f"calibrate-{b}-{rows}"
    out.mkdir(parents=True, exist_ok=True)
    rect = so.TARGET.get("window_rect") or [0, 0, W, H]
    full = so.Observer(*rect)
    s = Session(b, rows, out, log)
    rec = {"build": b, "rows": rows, "window_rect": rect}
    try:
        s.start()
        s.win = so.place(s.find_window(), W, H)
        i, _t, _w = s.expect("ready", READY_TIMEOUT_S)
        rec["ready"] = ready = ready_json(s.lines[i][1])
        try:
            rec["kpi_rect"] = s.kpi_from_build(ready)
        except BuildError as e:
            rec["kpi_rect"] = None
            rec["kpi_error"] = str(e)

        def shot(name, after_ns=0):
            full.wait_stable(SETTLE_MS * 3, 30, after_ns=after_ns)  # settled after the change, not before it
            ppm = out / f"{name}.ppm"
            full.dump(str(ppm))
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(ppm), str(out / f"{name}.png")], check=False)
            ppm.unlink(missing_ok=True)
            return full.last()[3]

        h0 = shot("step0")
        for n, name in ((1, "step1"), (0, "step0-again")):
            k0 = len(full.frames)
            start = len(s.lines)
            t_send = mono_ns()
            s.send(f"step {n}")
            s.expect("shown", STEP_TIMEOUT_S, arg=n, start=start)
            rec[f"{name}_hash"] = shot(name, t_send)
            rec[f"{name}_frames_changed"] = len({f[3] for f in full.frames[k0:]})
        rec["step0_hash"] = h0
        rec["step0_repeatable"] = rec["step0-again_hash"] == h0
        log(f"{b}: window {s.win['at']} {s.win['size']}; kpi {rec['kpi_rect']}; ready {json.dumps(ready)[:240]}")
        log(f"  distinct window pictures during step 1: {rec['step1_frames_changed']} (1 = numbers, chart and table in one frame); "
            f"step 0 repeats pixel-exactly: {rec['step0_repeatable']}; pictures in {out}")
    finally:
        full.close()
        s.close()
        (out / "calibrate.json").write_text(json.dumps(rec, indent=1) + "\n")
    return rec


# ---------------------------------------------------------------------------------------------------------------------
# selftest: the harness on a fake build (headless: no desktop, no window)
# ---------------------------------------------------------------------------------------------------------------------

FAKE_DRIVER = r'''
import json, sys, time, random
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import reference
rows, out, state, delay = sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4]), float(sys.argv[5])
want = reference.expected(rows)["steps"]
answers = [want[0]]
time.sleep(0.2)
state.write_text("0")
print("ready " + json.dumps({"kpi_rect": [0, 0, 100, 20], "load_ms": 200.0}), flush=True)
for line in sys.stdin:
    w = line.split()
    if w[0] == "step":
        n = int(w[1])
        state.write_text(f"busy{n}")          # a transitional picture first (a spinner), then the numbers
        time.sleep(delay + random.random() * delay)
        state.write_text(str(n))
        answers.append(want[n])
        time.sleep(0.02)
        print(f"shown {n} {delay * 1000:.2f} " + json.dumps({"compute_ms": delay * 500}), flush=True)
    elif w[0] == "quit":
        (out / "answers.json").write_text(json.dumps({"steps": answers}))
        print("bye", flush=True)
        break
'''


class FakeObserver(so.Observer):
    """A 60 Hz 'compositor' that shows the fake build's state file as the region's content."""

    def __init__(self, state):
        self.frames, self.info, self.dumps, self._cv = [], {"fake": True}, [], threading.Condition()
        self.state, self._stop, self.seq = state, threading.Event(), 0
        self._t = threading.Thread(target=self._tick, daemon=True)
        self._t.start()
        with self._cv:
            self._cv.wait_for(lambda: self.frames, 5)

    def _tick(self):
        nxt = mono_ns()
        while not self._stop.is_set():
            nxt += 16_666_667
            time.sleep(max(0, (nxt - mono_ns()) / 1e9))
            try:
                h = hashlib.sha1(self.state.read_bytes()).hexdigest()[:16]
            except OSError:
                h = "none"
            with self._cv:
                self.frames.append((self.seq, nxt, nxt + 4_000_000, h))
                self.seq += 1
                self._cv.notify_all()

    def close(self):
        self._stop.set()


def selftest(log, full=False):
    """Pure parts, then a fake build through one_run + summarise + report, then m5's build check on the result."""
    fails = []

    def ok(cond, what):
        (log if cond else fails.append)(("  ok   " if cond else "") + what)

    # quantiles
    ok(pct(list(range(1, 21)), 0.95) == 19 and pct([5], 0.95) == 5 and med([1, None, 3]) == 2, "nearest-rank p95, median")
    # latency matching: transitional frame, then the final picture
    fr = [(0, 100, 104, "a"), (1, 117, 121, "busy"), (2, 133, 137, "b"), (3, 150, 154, "b")]
    ok(so.first_match(fr, 110, "b") == (133, 137) and so.first_match(fr, 140, "b") == (150, 154)
       and so.first_match(fr, 110, "z") is None, "first frame showing the settled picture, after the injection")
    # nvidia-smi's process table
    table = ("|    0   N/A  N/A            1618      G   Hyprland                                 12MiB |\n"
             "|    1   N/A  N/A          123456      C   /usr/bin/python3                        900MiB |\n"
             "|    0   N/A  N/A            4242    C+G   ...chromium --type=gpu-process           64MiB |")
    gp = gpu_processes(table)
    ok(gp == [(0, 1618, "G", "Hyprland", 12), (1, 123456, "C", "/usr/bin/python3", 900), (0, 4242, "C+G", "...chromium --type=gpu-process", 64)],
       "nvidia-smi process table parsed (G, C, C+G)")
    g = Gate(log, desktop_pids={1618, 4242})
    ok([p[1] for p in g.busy_apps(gp, mine=set())] == [123456, 4242], "gate: a compute app and a C+G app are busy; the desktop's G client isn't")
    # correctness split
    S = len(reference.states()) - 1
    want = reference.expected("10M")["steps"]
    applied = [0] + [x for p in range(3) for x in ([0] if p else []) + list(range(1, S + 1))]
    good = {"steps": [want[n] for n in applied]}
    ok(check_answers(good, applied, "10M", 3) == (3, []), "correctness: three clean passes")
    bad = json.loads(json.dumps(good))
    bad["steps"][S + 5]["rows"] += 1
    c, p = check_answers(bad, applied, "10M", 3)
    ok(c == 3 and p and p[0].startswith("pass 2"), f"correctness: a wrong row count in pass 2 is caught ({p[:1]})")
    ok(check_answers({"steps": good["steps"][:-1]}, applied, "10M", 3)[1], "correctness: a missing answer is caught")
    # effort counting on the real tree
    e = effort()
    ok(all(e[b]["lines"] > 0 and e[b]["files"] > 0 and e[b]["languages"] for b in ORDER) and e["D"]["framework"]["lines"] > 0,
       f"effort: {', '.join(f'{b} {e[b]['lines']} lines/{e[b]['files']} files' for b in ORDER)}; D framework +{e['D']['framework_added']['lines']}")
    # a fake build end to end (headless: no window, a fake 60 Hz observer)
    WORK.mkdir(parents=True, exist_ok=True)
    drv = WORK / "fake_driver.py"
    drv.write_text(FAKE_DRIVER)
    state = WORK / "fake_state"
    state.write_text("boot")
    BUILDS["F"] = dict(BUILDS["C"], label="F · fake", web=False, driver_is_app=True, kpi_command=False,
                       cmd=["{python}", str(drv), str(ROOT / "showcase-data"), "10M", "{out}", str(state), "0.03"])
    fake_obs = lambda x, y, w, h: FakeObserver(state)  # noqa: E731
    env = dict(os.environ)
    try:
        t0 = time.time()
        g = no_gate(log)
        g.update({"gated": True, "load1": 0.1, "gpu_util": 0, "busy_gpu_apps": []})
        n_runs, n_pass, n_cold = (3, 10, 3) if full else (1, 2, 1)
        runs = [one_run("F", "10M", r + 1, lambda *_: None, g, passes=n_pass, observer=fake_obs, place=False, env=env) for r in range(n_runs)]
        colds = cold_runs("F", "10M", n_cold, lambda *_: None, lambda w: g, observer=fake_obs, place=False, env=env)
        for c in colds:
            c["window_mapped_ms"] = 1.0
        r = summarise("F", runs, colds, [])
        r["effort"] = e["C"]
        took = time.time() - t0
        ok(all(not x.get("void") for x in runs), f"fake build: {n_runs} run(s) × {WARM + n_pass} passes, none void ({[x.get('void') for x in runs if x.get('void')]})")
        s = r.get("summary") or {}
        ok(s and 30 <= s["median_of_medians_ms"] <= 120, f"fake build: observed median of medians {s.get('median_of_medians_ms')} ms "
           f"(the fake sleeps 30–60 ms + one frame), in-app {s.get('in_app_median_of_medians_ms')}")
        ok(all(v["first_change_median_ms"] is not None and v["first_change_median_ms"] < v["median_ms"] for v in r["per_step"].values()),
           "fake build: the transitional picture is seen before the numbers (first change < latency)")
        ok(r.get("compute_ms", {}).get("key") == "compute_ms", "fake build: compute figure picked up")
        ok(len(r["cold"]["process"]["runs_ms"]) == n_cold and "evicted" in r["cold"]["process"]["page_cache"], f"fake build: {n_cold} cold start(s), page cache stated")
        m = r["memory"]
        ok(m["sample_ms"] == 50 and m["pss_load_peak_mb"] > 0 and m["pss_steady_peak_mb"] and "python" in " ".join(m["processes"]),
           f"fake build: PSS sampled (load peak {m['pss_load_peak_mb']} MB, steady {m['pss_steady_peak_mb']} MB, sampler {m['sampler_cost_ms_median']} ms)")
        # m5's per-build check accepts the harness's own output shape (run on the fake, labelled C)
        spec = __import__("importlib.util").util.spec_from_file_location("check38", ROOT / "scripts/check.py")
        chk = __import__("importlib.util").util.module_from_spec(spec)
        spec.loader.exec_module(chk)
        r2 = json.loads(json.dumps(r))
        r2["memory"]["gpu_peak_mib"] = r2["memory"]["gpu_peak_mib"] or 0
        why = chk.m5_build("C", r2, S)
        if full:
            ok(why is None, f"check.py m5_build accepts the harness's output ({why})")
        else:
            ok(why and "valid runs" in why, f"check.py m5_build rejects a 1-run result ({why}); --full runs the protocol's shape")
        r3_ = json.loads(json.dumps(r2))
        r3_["runs"][0]["correctness"]["problems"] = ["pass 1: step 3: rows 1, want 2"]
        ok(chk.m5_build("C", r3_, S) is not None, "check.py m5_build rejects a run with a correctness problem")
        rep = report({"builds": {"C": r2}, "measured_at": "now", "rows": "10M", "provisional": True,
                      "environment": {"commit": "x" * 40, "cpu": "c", "gpu": "g", "driver": "d", "kernel": "k", "chromium": "ch",
                                      "rust": "r", "mojo": "m", "polars": "p", "duckdb": "dd", "data_lock": json.loads((ROOT / "showcase-data/data.lock").read_text())},
                      "desktop": {"compositor": "Hyprland", "monitor": {}}, "observer": {"method": "fake", "selftest": {}},
                      "protocol": {"runs": 3, "order": [["C"]], "warmup_passes": 2, "measured_passes": 10, "chromium": [CHROMIUM, *CHROMIUM_FLAGS]},
                      "caveats": CAVEATS})
        ok("| 32 |" in rep and "median of medians" in rep, f"report renders ({len(rep.splitlines())} lines)")
        log(f"  (fake build: {took:.0f} s for {n_runs} run(s) × {WARM + n_pass} passes + {n_cold} cold start(s))")
    finally:
        BUILDS.pop("F", None)
    return fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["plan", "selftest", "env", "count", "calibrate", "run", "report"])
    ap.add_argument("build", nargs="?")
    ap.add_argument("--builds", nargs="+", default=ORDER)
    ap.add_argument("--rows", default="100M", choices=["10M", "100M"])
    ap.add_argument("--passes", type=int, default=PASSES)
    ap.add_argument("--runs", type=int, default=RUNS)
    ap.add_argument("--cold", type=int, default=COLD)
    ap.add_argument("--display", choices=["headless", "desktop"], default="headless",
                    help="headless: a separate headless Hyprland on the GPU (default; the owner's session is locked); "
                         "desktop: the owner's live desktop (D-765)")
    ap.add_argument("--start-after", help="HH:MM: hold the run until then and until a job that starts then has finished")
    ap.add_argument("--busy-wait-s", type=int, default=1800)
    ap.add_argument("--full", action="store_true", help="selftest: the fake build at the protocol's full shape (~9 min)")
    ap.add_argument("--provisional", action="store_true", help="no quiet gate (a busy machine): results-provisional.*")
    a = ap.parse_args()
    log = lambda *x: print(*x, flush=True)  # noqa: E731
    if a.cmd == "plan":
        lines, total = plan(a.builds, a.runs, a.passes, a.cold)
        print(f"Run plan ({a.rows}, {a.runs} runs × {len(a.builds)} builds, {WARM} warm-up + {a.passes} measured passes, {a.cold} cold starts):")
        print("\n".join(lines))
        print(f"Expected: ~{total / 3600:.1f} h of measuring, plus any waiting at the quiet gate")
    elif a.cmd == "selftest":
        fails = selftest(log, full=a.full)
        print("FAIL:\n  " + "\n  ".join(fails) if fails else "selftest: PASS")
        sys.exit(1 if fails else 0)
    elif a.cmd == "env":
        comp = so.HeadlessHyprland() if a.display == "headless" else None
        rec = comp.start() if comp else None
        try:
            print(json.dumps({"environment": environment(), "desktop": desktop(rec)}, indent=1))
        finally:
            if comp:
                comp.stop()
    elif a.cmd == "count":
        print(json.dumps({b: {k: v for k, v in e.items() if k != "by_file"} for b, e in effort().items()}, indent=1))
    elif a.cmd == "calibrate":
        calibrate(a.build, a.rows, log, a.display)
    elif a.cmd == "report":
        p = OUT / "results.json"
        (OUT / "results.md").write_text(report(json.loads(p.read_text())))
    elif a.cmd == "run":
        missing = [b for b in a.builds if not BUILDS[b]["cmd"]]
        if missing:
            raise SystemExit(f"no external-drive command for {missing} yet (their README's driver contract)")
        res = run_all(a, log)
        print(f"wrote {write(res)}")


if __name__ == "__main__":
    main()
