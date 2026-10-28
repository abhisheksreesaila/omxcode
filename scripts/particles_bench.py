"""Goal 36 M4: one measurement protocol for every row of the particle showcase (showcase/SPEC.md).

    pixi run python scripts/particles_bench.py                 # build, measure every row and size, count the code
    pixi run python scripts/particles_bench.py --rows A C --sizes 1000000 --runs 1   # a quick subset (not written)
    pixi run python scripts/particles_bench.py --count         # only the code/effort counts (printed)

Writes docs/goals/36/results.json and docs/goals/36/results.md (full runs only).

The protocol, the same for all rows:
- One build at a time, nothing else of ours running; before each run it waits (up to 3 min) for the 1-minute load
  average to fall to LOAD_MAX and the GPU to be idle, and records both.
- A, A-cpu and C run on the same Xvfb display (scripts/headless.py); B-wasm runs in headless Chromium on the same GPU;
  B-native renders offscreen (NVIDIA's Vulkan driver can't present to Xvfb). Every GPU row asserts an NVIDIA adapter
  (never SwiftShader or llvmpipe).
- 60 warm-up frames, then 600 measured; three runs; each figure is the median of the three runs' figures, with the
  spread (max - min).
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
- Peak memory: one method for all rows: this script samples the resident memory (RSS) of the whole process tree it
  launched every 20 ms (the harness's own Python, Node (Playwright) and nvidia-smi excluded; GPU memory not counted);
  no row copies its positions out at the end (positions off).
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
LOAD_MAX = 6.0  # 1-minute load average (24 cores: a quarter busy) under which a run may start
LABEL = {
    "A": "A · JS + WebGPU", "A-cpu": "A-cpu · plain JS (CPU)", "B-wasm": "B-wasm · JS + Rust/wasm",
    "B-native": "B-native · Rust + wgpu", "C": "C · omxcode (Mojo)",
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


def wait_quiet(log):
    """Waits for a quiet machine (load and GPU); returns what it found when it started."""
    t0 = time.time()
    while True:
        load, util = os.getloadavg()[0], gpu_util()
        if (load <= LOAD_MAX and util <= 10) or time.time() - t0 > 180:
            if time.time() - t0 > 180:
                log(f"  (still busy after 3 min: load {load:.1f}, GPU {util}%; running anyway, recorded)")
            return {"load1": round(load, 2), "gpu_util": util, "waited_s": round(time.time() - t0)}
        time.sleep(5)


_EXCLUDE = {"python", "python3", "python3.13", "node", "nvidia-smi", "pixi", "Xvfb", "sh", "bash"}


class TreeRss:
    """Peak RSS (MB) of every process this script started (its descendants), sampled every 20 ms."""

    def __init__(self):
        self.peak, self._stop = 0, threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)
        self._t.start()

    @staticmethod
    def sample():
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
        total, todo = 0, list(kids.get(os.getpid(), []))
        while todo:
            q = todo.pop()
            todo += kids.get(q, [])
            if comm.get(q) not in _EXCLUDE:
                total += rss.get(q, 0)
        return total / 1024

    def _run(self):
        while not self._stop.is_set():
            self.peak = max(self.peak, self.sample())
            self._stop.wait(0.02)

    def stop(self):
        self._stop.set()
        self._t.join()
        return round(self.peak, 1)


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
        t = check_b.run_native(n, frames, out / "n", positions=False)
        adapter = t["adapter"]
        step_is = "GPU timestamp queries around the compute pass"
    _nvidia(adapter, row)
    iv = t["total"][WARM:]
    s = _stats(iv)
    return {
        "frame_ms": s["mean_interval_ms"],
        "frame_ms_is": "mean rAF interval, vsync/limiter off (headless)" if row == "B-wasm" else "mean loop interval (offscreen, two frames in flight)",
        **s, "step_ms": _med(t["step"][WARM:]), "step_ms_is": step_is,
        "gpu_frame_ms": None, "cpu_encode_ms": _med(t["work"][WARM:]) if row == "B-wasm" else None,
        "readback_ms": None, "cold_start_ms": t["cold_start_ms"], "adapter": adapter,
        **({"threads": t["threads"], "crossOriginIsolated": t["crossOriginIsolated"]} if row == "B-wasm" else {"present": t.get("present")}),
    }, out


def run_c(n):
    import check_c
    out = Path(tempfile.mkdtemp(prefix="bench_c_"))
    t, cold, _ = check_c.scripted(n, WARM + MEAS, out, positions=False, env={"GDK_DEBUG": "no-vsync"})
    _nvidia(t["device"], "C")
    s = _stats(t["total"][WARM:])
    step, splat, rb = _med(t["step"][WARM:]), _med(t["splat"][WARM:]), _med(t["readback"][WARM:])
    return {
        "frame_ms": s["mean_interval_ms"], "frame_ms_is": "mean canvas frame interval, GDK_DEBUG=no-vsync (GTK's frame clock uncapped)",
        **s, "step_ms": step, "step_ms_is": "GPU step, timed on a separate pass (each part waited for on its own)",
        "gpu_frame_ms": step + splat, "cpu_encode_ms": None, "readback_ms": rb,
        "work_ms": _med(t["work"][WARM:]), "splat_ms": splat,
        "cold_start_ms": cold, "adapter": t["device"],
    }, out


def one(row, n, threads=None):
    mem = TreeRss()
    try:
        if row in ("A", "A-cpu"):
            r, out = run_a(n, cpu=row == "A-cpu")
        elif row.startswith("B"):
            r, out = run_b(row, n, threads)
        else:
            r, out = run_c(n)
    finally:
        peak = mem.stop()
    r["peak_rss_mb"] = peak
    subprocess.run(["rm", "-r", "--", str(out)], check=False)  # (only the temp folder this run made)
    return r


# ---------- the protocol ----------

FIELDS = ["frame_ms", "p95_interval_ms", "median_interval_ms", "step_ms", "gpu_frame_ms", "cpu_encode_ms", "readback_ms",
          "work_ms", "splat_ms", "cold_start_ms", "peak_rss_mb"]


def combine(runs):
    out = {}
    for k in FIELDS:
        xs = [r[k] for r in runs if r.get(k) is not None]
        if xs:
            out[k] = round(statistics.median(xs), 3)
            out[k + "_spread"] = round(max(xs) - min(xs), 3)
    for k in ("frame_ms_is", "step_ms_is", "adapter", "threads", "crossOriginIsolated", "present"):
        if k in runs[0]:
            out[k] = runs[0][k]
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


def bench(rows, sizes, runs, log):
    results = {}
    for row in rows:
        results[row] = {}
        for n in EXTRA.get(row, []) + sizes:
            threads = None
            probe = None
            if row == "B-wasm":  # the pool at every core and at cores - 2: keep the better (one probe run each)
                cores = os.cpu_count()
                tried = {}
                for th in (cores, cores - 2):
                    q = wait_quiet(log)
                    tried[th] = one(row, n, th)["frame_ms"]
                    log(f"  B-wasm {n:>10,} probe {th} threads: {tried[th]:.3f} ms (load {q['load1']})")
                threads = min(tried, key=tried.get)
                probe = {str(k): round(v, 3) for k, v in tried.items()}
            rr = []
            for i in range(runs):
                q = wait_quiet(log)
                r = one(row, n, threads)
                r["machine"] = q
                rr.append(r)
                log(f"  {row:8} {n:>10,} run {i + 1}: frame {r['frame_ms']:.3f} ms (p95 {r['p95_interval_ms']:.2f}), "
                    f"step {r['step_ms'] if r['step_ms'] is None else round(r['step_ms'], 3)}, cold {r['cold_start_ms']:.0f} ms, "
                    f"peak {r['peak_rss_mb']:.0f} MB; load {q['load1']}, GPU {q['gpu_util']}%")
            c = combine(rr)
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
    "B": {"dir": "showcase/js-rust", "skip": ["check_b.py", "Cargo.lock"]},
    "C": {"dir": "examples/particles", "skip": []},
}


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
        "C": ["pixi install  (Mojo 1.1, MAX 26.6)", *shell_commands_c(), "build/particles/linux/particles"],
    }
    out = {}
    for b in BUILDS:
        files = build_files(b)
        tools = []
        for s in steps[b]:
            w = s.split()[0]
            t = TOOLCHAIN.get(w) or (TOOLCHAIN["cargo"] if w.startswith("RUSTC_BOOTSTRAP") else None)
            if t and t not in tools:
                tools.append(t)
        if b in ("A", "A-cpu", "B"):
            tools.append("Chromium with WebGPU" if b == "A" else "Chromium")
        out[b] = {
            "files": len(files), "lines": sum(code_lines(f) for f in files),
            "by_file": {str(f.relative_to(ROOT)): code_lines(f) for f in files},
            "languages": languages(files), "build_steps": len(steps[b]), "steps": steps[b], "toolchains": tools,
        }
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
    L.append("# Goal 36 M4 · the particle field, measured\n")
    L.append(f"Commit `{res['commit']}`, sources sha256 `{res['sources_sha256'][:12]}`, {res['date']}; {res['machine']}.\n"
             f"Protocol: scripts/particles_bench.py (docstring): {WARM} warm-up + {MEAS} measured frames, {RUNS} runs, "
             "median of the runs (± spread = max - min).\n")
    L.append("## Headline: frame ms (throughput, vsync off) and the largest N at 60 fps\n")
    L.append("Holds 60 fps = frame ms ≤ 16.7 and the 95th-percentile frame interval ≤ 20 ms.\n")
    sizes = SIZES
    L.append("| Row | largest N at 60 fps | " + " | ".join(mill(n) for n in sizes) + " |")
    L.append("|---|---|" + "---|" * len(sizes))
    for row in R:
        big = largest_60(R[row])
        cells = []
        for n in sizes:
            r = R[row].get(str(n))
            cells.append("–" if not r else f"{fmt(r['frame_ms'])} ±{fmt(r['frame_ms_spread'])}" + ("" if r["holds_60"] else " ✗"))
        L.append(f"| {LABEL[row]} | {mill(big) if big else 'none'} | " + " | ".join(cells) + " |")
    if "100000" in R.get("A-cpu", {}):
        r = R["A-cpu"]["100000"]
        L.append(f"\nA-cpu at 100k: {fmt(r['frame_ms'])} ms ±{fmt(r['frame_ms_spread'])}"
                 f" ({'holds' if r['holds_60'] else 'does not hold'} 60 fps; p95 {fmt(r['p95_interval_ms'])} ms).")
    L.append("\nHow each row's frame ms is measured:\n")
    for row in R:
        r = next(iter(R[row].values()))
        L.append(f"- {LABEL[row]}: {r['frame_ms_is']}.")
    L.append("\n## Separately (labelled; not comparable across rows unless the label matches)\n")
    L.append("| Row | N | p95 interval | step ms | step is | GPU frame ms | CPU encode ms | readback ms | cold start ms | peak RSS MB |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for row in R:
        for n, r in sorted(R[row].items(), key=lambda kv: int(kv[0])):
            L.append(f"| {row} | {mill(int(n))} | {fmt(r.get('p95_interval_ms'))} | {fmt(r.get('step_ms'), 3)} | {r['step_ms_is']} | "
                     f"{fmt(r.get('gpu_frame_ms'), 3)} | {fmt(r.get('cpu_encode_ms'), 3)} | {fmt(r.get('readback_ms'), 3)} | "
                     f"{fmt(r.get('cold_start_ms'), 0)} | {fmt(r.get('peak_rss_mb'), 0)} |")
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
        L.append(f"| {b} | {e['lines']} | {e['files']} | {', '.join(e['languages'])} | {e['build_steps']} | {'; '.join(e['toolchains'])} |")
    L.append("\nLines exclude blank and comment-only lines (and docstrings). C counts the app (examples/particles) only: "
             "mojoui (the framework, including PointCloud's step/splat kernels) is a library, as WebGPU, wgpu, "
             "wasm-bindgen and rayon are. Build steps, clean checkout to running:\n")
    for b, e in E.items():
        L.append(f"- {b}: " + " → ".join(f"`{s}`" for s in e["steps"]))
    L.append("\n## Caveats (every one)\n")
    for c in CAVEATS:
        L.append(f"- {c}")
    return "\n".join(L) + "\n"


CAVEATS = [
    "A draws with an atomic compute rasteriser (two u32 atomics per on-screen particle) and skips the second atomic once "
    "a pixel is saturated (its count is past the tone map's white for the dimmest channel); its look is a tone map, not "
    "the SPEC's clamp. ?render=points (hardware point blending) exists and is about half as fast at 20M.",
    "C's splat is the framework's generic PointCloud.splat: three u32 atomics per particle (r, g, b), each skipped once "
    "that channel's sum is saturated (an atomic load first; exact: the GPU still matches the CPU path).",
    "B draws with hardware blending (WebGL2 points / wgpu point list, additive). B-wasm steps on the CPU (wasm SIMD + a "
    "rayon pool in a worker) and uploads one packed u32 per particle to the GPU every frame.",
    "C copies its finished picture (1280 × 720 × 4 bytes) from the GPU to the CPU every frame and hands it to GTK as a "
    "texture: that is the framework's Canvas path today. readback ms is that copy alone, measured on the separate pass.",
    "C's step ms comes from a separate timed pass after the measured frames (Mojo 1.1's DeviceEvent has no elapsed time; "
    "the frame loop waits for the GPU once a frame, so it can't split step from splat).",
    "C runs in the real GTK host on Xvfb, where GTK composites with its cairo (software) renderer; on a real display GTK "
    "uses its GL renderer. A and A-cpu run in Chromium on the same Xvfb display (ANGLE/Vulkan, no Vulkan surface).",
    "C's frame clock is capped at 60 fps by GTK unless GDK_DEBUG=no-vsync (verified: 16.7 ms at every N with the cap, "
    "4.8 ms at 1M without), so its headline is measured uncapped.",
    "A's headline comes from &await=0 with the queue drained at the warm-up's end: Chromium's onSubmittedWorkDone round "
    "trip (5-9 ms here) would otherwise dominate, and the rAF interval alone runs ahead of the GPU.",
    "B-native renders offscreen only (NVIDIA's Vulkan driver can't present to Xvfb), two frames in flight: it never "
    "presents to a window here.",
    "B-wasm runs in headless Chromium (no Xvfb), WebGL2 through ANGLE on NVIDIA's EGL (OpenGL), the fastest path found.",
    "A-cpu is single-threaded by design (plain JS on the main thread, the 'JS alone' baseline); it uses no GPU for the "
    "step, and Chromium composites its canvas.",
    "Peak memory is the RSS of the launched process tree (Chromium's processes, or the one native process), sampled every "
    "20 ms; GPU memory is not included. C keeps a CPU copy of all points (16 bytes each) by design of PointCloud.",
    "Cold start includes each runtime's own start: Chromium's for A, A-cpu and B-wasm; the GPU driver's for all.",
    "The machine has two RTX 3090s; each runtime picks its own (all report an NVIDIA GeForce RTX 3090). Runs wait for a "
    f"1-minute load ≤ {LOAD_MAX} and an idle GPU; each run's load is recorded.",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", nargs="+", default=ROWS)
    ap.add_argument("--sizes", nargs="+", type=int, default=SIZES)
    ap.add_argument("--runs", type=int, default=RUNS)
    ap.add_argument("--count", action="store_true")
    ap.add_argument("--no-build", action="store_true")
    a = ap.parse_args()
    if a.count:
        print(json.dumps(effort(), indent=1))
        return
    full = a.rows == ROWS and a.sizes == SIZES and a.runs == RUNS
    if full and dirty():
        raise SystemExit("particles_bench: commit the sources first (results must come from a commit):\n" + dirty())
    headless.ensure()
    quiet_harness()
    log = lambda s: print(s, flush=True)  # noqa: E731
    sha = sources_sha()
    if not a.no_build:
        build(log)
    t0 = time.time()
    rows = bench(a.rows, a.sizes, a.runs, log)
    if sources_sha() != sha:
        raise SystemExit("particles_bench: the sources changed during the run; results not written")
    gpu = subprocess.run(["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"], capture_output=True, text=True).stdout.strip().splitlines()
    res = {
        "commit": subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
        "sources_sha256": sha, "date": time.strftime("%Y-%m-%d %H:%M"), "seconds": round(time.time() - t0),
        "machine": f"{os.cpu_count()} cores, {', '.join(gpu)}",
        "protocol": {"warmup": WARM, "frames": MEAS, "runs": RUNS, "sizes": SIZES, "extra_sizes": EXTRA,
                     "frame_60_ms": round(FRAME_60, 3), "p95_max_ms": P95_MAX, "load_max": LOAD_MAX},
        "rows": rows, "largest_n_at_60": {row: largest_60(rows[row]) for row in rows},
        "effort": effort(), "caveats": CAVEATS,
    }
    if not full:
        print(json.dumps({r: {n: {k: v for k, v in x.items() if k != "runs"} for n, x in rows[r].items()} for r in rows}, indent=1))
        return
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "results.json").write_text(json.dumps(res, indent=1) + "\n")
    (OUT / "results.md").write_text(report(res))
    print(f"wrote {OUT / 'results.json'} and results.md ({res['seconds']} s)")


if __name__ == "__main__":
    main()
