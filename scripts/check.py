"""Milestone checker for GOAL.md (goal 36: three stacks, one particle field). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M4)
Each milestone's proof comes from GOAL.md's words (never weaker). M1-M3 run each build's own check script and need
its "ok" lines; M4 checks docs/goals/36/results.json, written by scripts/particles_bench.py.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "docs" / "goals" / "36"


def run(cmd, timeout=3600):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)


def needs_ok(cmd, labels, timeout=3600):
    """Runs a build's check; every label must print '<label>: ok'."""
    r = run([sys.executable, *cmd], timeout)
    out = r.stdout + r.stderr
    lines = [l.strip() for l in out.splitlines()]
    missing = [lab for lab in labels if not any(l.startswith(f"{lab}: ok") for l in lines)]
    if r.returncode != 0 or missing:
        tail = " | ".join(l for l in lines if l)[-900:]
        return False, f"{' '.join(cmd)}: exit {r.returncode}, no ok for {missing or labels}: {tail}"
    return True, "; ".join(next(l for l in lines if l.startswith(f"{lab}: ok")) for lab in labels)


def m0():
    """The spec and the reference: SPEC.md and reference.py; N = 10,000 after 120 steps, two runs byte-equal."""
    for f in ("showcase/SPEC.md", "showcase/reference.py"):
        if not (ROOT / f).exists():
            return False, f"{f} missing"
    with tempfile.TemporaryDirectory() as d:
        outs = []
        for k in range(2):
            p = Path(d) / f"ref{k}.bin"
            r = run([sys.executable, "showcase/reference.py", "10000", "120", str(p)], 600)
            if r.returncode != 0 or not p.exists():
                return False, f"reference.py failed: {r.stderr[-500:]}"
            outs.append(p.read_bytes())
    if len(outs[0]) != 10000 * 2 * 4:
        return False, f"reference wrote {len(outs[0])} bytes, not 10,000 × 2 float32"
    if outs[0] != outs[1]:
        return False, "two reference runs differ"
    import hashlib
    return True, f"reference N=10,000 F=120: two runs byte-equal ({len(outs[0])} bytes, sha256 {hashlib.sha256(outs[0]).hexdigest()[:12]})"


def m1():
    """A · JS + WebGPU on the RTX 3090 matches the reference, and the plain-JS CPU row (A-cpu)."""
    ok1, msg1 = needs_ok(["showcase/js-webgpu/check_a.py"], ["A"])
    ok2, msg2 = needs_ok(["showcase/js-webgpu/check_a.py", "--cpu"], ["A-cpu"])
    return ok1 and ok2, f"{msg1}; {msg2}"


def m2():
    """B · JS + Rust: the wasm row and the native wgpu row both match the reference."""
    return needs_ok(["showcase/js-rust/check_b.py"], ["B-wasm", "B-native"])


def m3():
    """C · omxcode: examples/particles on GTK (GPU) matches the reference."""
    return needs_ok(["showcase/omxcode/check_c.py"], ["C"])


def m4():
    """The measure: results.json is the final gated measurement (not provisional), every row at every size, from one
    protocol, fresh for these sources."""
    import particles_bench as pb
    path = OUT / "results.json"
    if not path.exists() or not (OUT / "results.md").exists():
        prov = " (only the PROVISIONAL busy-machine results exist: results-provisional.json)" if (OUT / "results-provisional.json").exists() else ""
        return False, "docs/goals/36/results.json or results.md missing: run scripts/particles_bench.py through the quiet gate" + prov
    res = json.loads(path.read_text())
    problems = []
    if res.get("provisional") is not False or res.get("gated") is not True or not (res.get("protocol", {}).get("gate") or {}).get("load1_below"):
        problems.append("results.json is not the final gated measurement (provisional or ungated)")
    if "PROVISIONAL" in (OUT / "results.md").read_text():
        problems.append("results.md is marked PROVISIONAL")
    if res.get("sources_sha256") != pb.sources_sha():
        problems.append("stale: the sources changed since results.json was measured (rerun scripts/particles_bench.py)")
    p = res.get("protocol", {})
    if (p.get("warmup"), p.get("frames"), p.get("runs")) != (60, 600, 3):
        problems.append(f"protocol {p.get('warmup')}/{p.get('frames')}/{p.get('runs')}, not 60 warm-up / 600 frames / 3 runs")
    need = ["frame_ms", "frame_ms_spread", "p95_interval_ms", "cold_start_ms", "peak_rss_mb", "holds_60", "frame_ms_is", "step_ms_is"]
    for row in pb.ROWS:
        rows = res.get("rows", {}).get(row)
        if not rows:
            problems.append(f"{row}: no results")
            continue
        for n in pb.EXTRA.get(row, []) + pb.SIZES:
            r = rows.get(str(n))
            if not r:
                problems.append(f"{row} {n}: missing")
                continue
            miss = [k for k in need if r.get(k) is None]
            if miss:
                problems.append(f"{row} {n}: no {miss}")
            if not all((x.get("machine") or {}).get("gated") for x in r.get("runs", [])) or not r.get("machine", {}).get("gated"):
                problems.append(f"{row} {n}: a run didn't pass the quiet gate")
            if len(r.get("runs", [])) != 3:
                problems.append(f"{row} {n}: {len(r.get('runs', []))} runs")
            if row != "A-cpu":
                a = (r.get("adapter") or "").lower()
                if "nvidia" not in a or "swiftshader" in a or "llvmpipe" in a:
                    problems.append(f"{row} {n}: adapter {r.get('adapter')}")
            if row == "C" and r.get("readback_ms") is None:
                problems.append(f"C {n}: no readback_ms")
            if row == "B-wasm" and (not r.get("crossOriginIsolated") or r.get("threads", 1) <= 1):
                problems.append(f"B-wasm {n}: not multi-threaded")
            if r.get("holds_60") != (r.get("frame_ms", 99) <= 1000 / 60 and r.get("p95_interval_ms", 99) <= 20):
                problems.append(f"{row} {n}: holds_60 disagrees with its numbers")
    for b in ("A", "A-cpu", "B", "C"):
        e = res.get("effort", {}).get(b, {})
        if not all(e.get(k) for k in ("lines", "files", "languages", "build_steps", "toolchains")):
            problems.append(f"effort {b}: incomplete")
    if res.get("effort") and res["effort"] != pb.effort():
        problems.append("effort counts differ from a fresh count")
    md = (OUT / "results.md").read_text()
    for word in ("atomic", "saturat", "hardware blending", "readback", "offscreen", "single-threaded"):
        if word not in md:
            problems.append(f"results.md doesn't state the caveat '{word}'")
    if problems:
        return False, "; ".join(problems[:12])
    big = res["largest_n_at_60"]
    return True, (f"results.json fresh (commit {res['commit']}, sources {res['sources_sha256'][:10]}); largest N at 60 fps: "
                  + ", ".join(f"{r} {pb.mill(v) if v else 'none'}" for r, v in big.items()))


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


MILESTONES = [
    ("M0", m0),
    ("M1", m1),
    ("M2", m2),
    ("M3", m3),
    ("M4", m4),
    ("M5", todo("docs/why.html, the page in four chapters")),
]


def main():
    import headless
    headless.ensure()
    only = sys.argv[1:]
    results = []
    for name, fn in MILESTONES:
        if only and name not in only:
            continue
        t0 = time.time()
        try:
            ok, msg = fn()
        except Exception as e:
            import traceback
            traceback.print_exc()
            ok, msg = False, f"crashed: {e!r}"
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}  {msg}  ({time.time() - t0:.0f} s)", flush=True)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
