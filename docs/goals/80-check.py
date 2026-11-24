"""Milestone checker for GOAL.md (goal 80: the best 2D renderer, by borrowing what the best do).
Prints "Mn: PASS|FAIL|BLOCKED  why" per milestone.

    pixi run python docs/goals/80-check.py [M0 M1 ...]          (default: every milestone; scripts/check runs this)

Written before the renderer work (2026-11-22) from GOAL.md's words; never edited to make a milestone pass (add, don't
weaken; checker bugs are logged in docs/decisions.md with why the fix is not a weakening). The bars live here, not in
the tests: tests print facts (`IDENTICAL a/b`, `SPEEDUP x`, `... ok`), this file judges them.

The race: nanoui (github.com/justrach/nanoui) at NANOUI_REV, built with Zig ZIG_VER into build/g80, plus our GL timing
patch (bench/nanoui/nanoui-gl.patch, bench/nanoui/glrun.zig: the only change to nanoui), against
bench/nanoui/scenes.mojo on gpu2d. Both headless (EGL), same GPU, nanoui's rules (900×640 at 2x, 30 + 300 frames,
best of 3 runs). Both print `RESULT {json}` lines per scene.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
OUT = ROOT / "build" / "g80"
DOCS = ROOT / "docs" / "goals" / "80"
BASE_REV = "3686e45b"
NANOUI_REV = "cfe6000"
ZIG_VER = "0.17.0"
ZIG = OUT / f"zig-x86_64-linux-{ZIG_VER}" / "zig"
NANOUI = OUT / "nanoui"
OMX = OUT / "omxbench"
MAC_SSH = os.environ.get("MAC_SSH", "bhoomijaprasad@100.76.9.101")
MAC_KEY = os.path.expanduser(os.environ.get("MAC_SSH_KEY", "~/.ssh/edx_mac"))

RACE = ["boxes", "text", "scroll", "list", "dashboard"]
HELD = ["whiteboard", "canvas", "mindmap", "document", "table"]

# ---- the bars, from GOAL.md ----
SPEEDUP_MIN = 4.0     # M5: median threaded speed-up over the race scenes
TIE_MAX = 1.03        # M6, M7: a race cell vs the rival's (the owner, 2026-11-23: "3% is good enough", D-8025; was 1.0)
HELD_MAX = 1.05       # M6: each held-out scene's frame CPU and GPU medians vs the base's, alternated in one session (D-8029)
RIVAL_WORDS = r"nanoui|hillclimb|boxes|dashboard"  # M6: may not appear more often in mojoui/ than at BASE_REV


def run(cmd, timeout, cwd=ROOT, env=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=e)
    except subprocess.TimeoutExpired as x:
        return subprocess.CompletedProcess(cmd, 124, x.stdout or "", (x.stderr or "") + f"\ntimeout after {timeout}s")


def tail(s, n=300):
    s = (s or "").strip()
    return s[-n:].replace("\n", " | ")


def results(text):
    out = {}
    for line in text.splitlines():
        if line.startswith("RESULT "):
            d = json.loads(line[7:])
            out[d["scene"]] = d
    return out


RUNS = 3              # (D-8012) interleaved race runs per side; each metric's lowest is kept


def best_of(runs):
    """(D-8012) Per scene, each metric's lowest over the runs: unchanged code read 3.4x apart on the GPU between runs
    (its clocks move between P8 and P0 under this light load), so one run proves nothing either way. Both sides alike."""
    return {s: {k: (v if k == "scene" else min(r[s][k] for r in runs)) for k, v in runs[0][s].items()} for s in runs[0]}


class awake:
    """(D-8030) Holds the GPU at its working clock while something is timed, by asking nvidia-smi for it every 50 ms (no
    setting is changed); .spread is the lowest and highest graphics clock read."""
    def __enter__(self):
        self.p = subprocess.Popen(["nvidia-smi", "-i", "0", "--query-gpu=clocks.gr", "--format=csv,noheader,nounits", "-lms", "50"], stdout=subprocess.PIPE, text=True)
        time.sleep(1.5)
        return self

    def __exit__(self, *a):
        self.p.terminate()
        v = sorted(int(x) for x in self.p.stdout.read().split() if x.isdigit())
        self.spread = (v[0], v[-1]) if v else (0, 0)
        return False


# ---------- builds (once per checker run) ----------
_cache = {}


def build_nanoui():
    if "nanoui" in _cache:
        return _cache["nanoui"]
    OUT.mkdir(parents=True, exist_ok=True)
    err = None
    if not ZIG.exists():
        r = run(["bash", "-c", f"curl -sL https://ziglang.org/download/{ZIG_VER}/zig-x86_64-linux-{ZIG_VER}.tar.xz | tar xJ"], 900, cwd=OUT)
        if r.returncode != 0 or not ZIG.exists():
            err = "zig download: " + tail(r.stderr)
    if err is None and not (NANOUI / ".git").exists():
        r = run(["git", "clone", "-q", "https://github.com/justrach/nanoui", str(NANOUI)], 900, cwd=OUT)
        if r.returncode != 0:
            err = "clone: " + tail(r.stderr)
    if err is None:
        hc = NANOUI / "hillclimb"
        steps = [
            ["git", "checkout", "-q", "--force", NANOUI_REV],
            ["git", "clean", "-q", "-fd", "hillclimb/src"],
            ["git", "apply", str(ROOT / "bench/nanoui/nanoui-gl.patch")],
            ["cp", str(ROOT / "bench/nanoui/glrun.zig"), str(hc / "src" / "glrun.zig")],
        ]
        for s in steps:
            r = run(s, 300, cwd=NANOUI)
            if r.returncode != 0:
                err = " ".join(s[:2]) + ": " + tail(r.stderr)
                break
    if err is None:
        r = run([str(ZIG), "build", "-Doptimize=ReleaseFast"], 1800, cwd=NANOUI / "hillclimb")
        if r.returncode != 0:
            err = "zig build: " + tail(r.stderr, 600)
    _cache["nanoui"] = err
    return err


def build_omx():
    if "omx" in _cache:
        return _cache["omx"]
    OUT.mkdir(parents=True, exist_ok=True)
    r = run(["pixi", "run", "mojo", "build", "-O3", "-I", ".", "bench/nanoui/scenes.mojo", "-o", str(OMX)], 1800)
    _cache["omx"] = None if r.returncode == 0 and OMX.exists() else "mojo build: " + tail(r.stdout + r.stderr, 600)
    return _cache["omx"]


def _nanoui_gl(scenes):
    exe = str(NANOUI / "hillclimb" / "zig-out" / "bin" / "hillclimb")
    g = run([exe, "--only", "nanoui", "--no-history", "--scene", ",".join(scenes)], 3600, env={"HC_GL": "1", "HC_SHOT": str(OUT / "shots")})
    # (it repeats each scene 3 times itself and keeps the lowest median; glrun.zig prints all three: the lowest is kept)
    out = {}
    for line in (g.stdout + g.stderr).splitlines():
        i = line.find("RESULT {")
        if i >= 0:
            d = json.loads(line[i + 7:])
            if d["scene"] not in out or d["frame_med"] < out[d["scene"]]["frame_med"]:
                out[d["scene"]] = d
    return out, tail(g.stdout + g.stderr, 600)


def _omx_run(scenes):
    r = run(["pixi", "run", str(OMX)] + scenes, 7200, env={"HC_SHOT": str(OUT / "shots")})
    return results(r.stdout), tail(r.stdout + r.stderr, 600)


def races():
    """(nanoui, omxcode, error): RUNS interleaved runs of both, each metric's lowest."""
    if "races" in _cache:
        return _cache["races"]
    err = build_nanoui() or build_omx()
    if err:
        _cache["races"] = (None, None, err)
        return _cache["races"]
    (OUT / "shots").mkdir(parents=True, exist_ok=True)
    ns, os_, clocks = [], [], []
    for _ in range(RUNS):
        n, o, mhz = {}, {}, {}
        for sc in RACE:  # (D-8030: a scene a process, both sides alike, each with the card held awake)
            with awake() as an:
                d, said = _nanoui_gl([sc])
            if sc not in d:
                _cache["races"] = (None, None, f"nanoui GL run, {sc}: " + said)
                return _cache["races"]
            n[sc] = d[sc]
            with awake() as ao:
                d, said = _omx_run([sc])
            if sc not in d:
                _cache["races"] = (None, None, f"omx run, {sc}: " + said)
                return _cache["races"]
            o[sc] = d[sc]
            mhz[sc] = {"nanoui": an.spread[1], "omx": ao.spread[1]}
        d, said = _omx_run(HELD)  # (race.md's held-out table and M0; M6 compares them by held_ab)
        o.update(d)
        clocks.append(mhz)
        c = run([str(NANOUI / "hillclimb" / "zig-out" / "bin" / "hillclimb"), "--only", "nanoui", "--no-history", "--scene", ",".join(RACE)], 3600)
        scene = None
        for line in re.sub(r"\x1b\[[0-9;]*[mK]", "", c.stdout + c.stderr).splitlines():
            m = re.search(r"(\w+)\s+frame CPU \(median\)", line)
            if m:
                scene = m.group(1)
            m = re.match(r"^\s+encode CPU\s+([\d.]+)", line)
            if m and scene in n:
                n[scene]["raster_med"] = float(m.group(1))
        if any("raster_med" not in n[s] for s in RACE):
            _cache["races"] = (None, None, "nanoui CPU run: " + tail(c.stdout + c.stderr, 600))
            return _cache["races"]
        if len(o) != len(RACE) + len(HELD):
            _cache["races"] = (None, None, "omx run: " + said)
            return _cache["races"]
        ns.append(n)
        os_.append(o)
        (DOCS / "race-awake.json").write_text(json.dumps({"peak clock MHz": clocks, "nanoui": ns, "omx": os_}, indent=1) + "\n")
    _cache["races"] = (best_of(ns), best_of(os_), None)
    return _cache["races"]


def race_nanoui():
    n, _, err = races()
    return n, err


def race_omx():
    _, o, err = races()
    return o, err


HELD_REV = "184973be"  # (D-8029) the bench program the recorded baseline used: its held-out scenes are today's
HELD_ROUNDS = 8        # (D-8029) alternating rounds, the order swapped each round; set before the first run under this rule


def held_ab():
    """(D-8029, the owner's OK 2026-11-23) The held-out scenes, base mojoui/ and today's alternated in one session:
    ({scene: base}, {scene: now}, error), each metric's lowest of HELD_ROUNDS, as the race. Every round is kept."""
    err = build_omx()
    if err:
        return None, None, err
    src = OUT / "basesrc"
    exe = OUT / "omx_heldbase"
    src.mkdir(parents=True, exist_ok=True)
    r = run(["bash", "-c", f"git archive {BASE_REV} | tar x -C {src} && mkdir -p {src}/bench/nanoui && git show {HELD_REV}:bench/nanoui/scenes.mojo > {src}/bench/nanoui/scenes.mojo"], 300)
    if r.returncode != 0:
        return None, None, "base source: " + tail(r.stderr)
    r = run(["pixi", "run", "mojo", "build", "-O3", "-I", str(src), str(src / "bench/nanoui/scenes.mojo"), "-o", str(exe)], 1800)
    if r.returncode != 0:
        return None, None, "base build: " + tail(r.stdout + r.stderr, 600)
    sides = {"base": exe, "now": OMX}
    got = {"base": [{} for _ in range(HELD_ROUNDS)], "now": [{} for _ in range(HELD_ROUNDS)]}
    clocks = {}
    for k in range(HELD_ROUNDS):
        for sc in HELD:  # (a scene a process: the base's long CPU raster between scenes lets the card doze off)
            for side in (("base", "now") if k % 2 == 0 else ("now", "base")):
                with awake() as aw:
                    r = run(["pixi", "run", str(sides[side]), sc], 3600)
                d = results(r.stdout)
                if sc not in d:
                    return None, None, f"held-out {side} {sc} run: " + tail(r.stdout + r.stderr, 600)
                got[side][k][sc] = d[sc]
                clocks.setdefault(sc, {}).setdefault(side, []).append(aw.spread[1])
        (DOCS / "held-ab.json").write_text(json.dumps({"base": BASE_REV, "bench": HELD_REV, "peak clock MHz": clocks, "rounds": got}, indent=1) + "\n")
    return best_of(got["base"]), best_of(got["now"]), None


def write_race(n, o):
    DOCS.mkdir(parents=True, exist_ok=True)
    base = json.loads((DOCS / "baseline.json").read_text())["scenes"] if (DOCS / "baseline.json").exists() else {}
    L = ["# Goal 80 race (generated by docs/goals/80-check.py; don't edit)", "",
         "Medians and p95 in ms per frame, lower is better. Same machine, headless GL, nanoui's scenes and rules.", "",
         "| scene | frame CPU n / o | frame p95 n / o | GPU n / o | GPU p95 n / o | CPU fallback n / o | instances n / o | GPU split o (upload / draw / resolve) |",
         "|---|---|---|---|---|---|---|---|"]
    for s in RACE:
        a, b = n[s], o[s]
        split = " / ".join(str(b.get(k, "—")) for k in ("gpu_upload", "gpu_draw", "gpu_resolve"))
        L.append(f"| {s} | {a['frame_med']} / {b['frame_med']} | {a['frame_p95']} / {b['frame_p95']} | {a['gpu_med']} / {b['gpu_med']} | "
                 f"{a['gpu_p95']} / {b['gpu_p95']} | {a['raster_med']} / {b['raster_med']} | {a['instances']} / {b['instances']} | {split} |")
    L += ["", "Held-out scenes (ours): now vs the recorded baseline, for the record only: M6 judges them by alternating base and now in one session (held-ab.json, D-8029).", "",
          "| scene | frame CPU base / now | GPU base / now | CPU fallback base / now | instances base / now |", "|---|---|---|---|---|"]
    for s in HELD:
        b = o[s]
        z = base.get(s, {})
        L.append(f"| {s} | {z.get('frame_med', '—')} / {b['frame_med']} | {z.get('gpu_med', '—')} / {b['gpu_med']} | "
                 f"{z.get('raster_med', '—')} / {b['raster_med']} | {z.get('instances', '—')} / {b['instances']} |")
    (DOCS / "race.md").write_text("\n".join(L) + "\n")


def inked(path):
    if not path.exists():
        return False
    if path.suffix == ".bgra":
        a = np.frombuffer(path.read_bytes(), dtype=np.uint8)
    else:
        a = np.asarray(Image.open(path).convert("RGB")).reshape(-1)
    return a.size > 0 and int(a.max()) - int(a.min()) > 64


def mojo_test(path, ok_line, timeout=3600):
    if not (ROOT / path).exists():
        return f"{path} missing", ""
    r = run(["pixi", "run", "mojo", "run", "-I", ".", path], timeout)
    out = r.stdout + r.stderr
    if r.returncode != 0 or ok_line not in out:
        return f"{path}: " + tail(out, 400), out
    return None, out


# ---------- milestones ----------

def m0():
    n, err = race_nanoui()
    if err:
        return "FAIL", err
    o, err = race_omx()
    if err:
        return "FAIL", err
    missing = [s for s in RACE if not inked(OUT / "shots" / f"nanoui-{s}.bgra")]
    missing += [s for s in RACE + HELD if not inked(OUT / "shots" / f"omx-{s}.png")]
    if missing:
        return "FAIL", "frames missing or blank: " + ", ".join(missing)
    bl = DOCS / "baseline.json"
    if not bl.exists():
        DOCS.mkdir(parents=True, exist_ok=True)
        head = run(["git", "rev-parse", "--short", "HEAD"], 60).stdout.strip()
        bl.write_text(json.dumps({"commit": head, "scenes": o}, indent=1) + "\n")
        write_race(n, o)
        return "FAIL", f"baseline.json written now (at {head}): commit it before any renderer change, then rerun"
    write_race(n, o)
    if run(["git", "ls-files", "--error-unmatch", str(bl)], 60).returncode != 0:
        return "FAIL", "baseline.json is not committed"
    first = run(["git", "log", "--diff-filter=A", "--format=%h", "--", str(bl)], 60).stdout.split()
    if not first:
        return "FAIL", "baseline.json has no commit adding it"
    changed = run(["git", "diff", "--stat", BASE_REV, first[-1], "--", "mojoui/"], 60).stdout.strip()
    if changed:
        return "FAIL", f"baseline committed at {first[-1]} after mojoui/ changed: {tail(changed, 200)}"
    base = json.loads(bl.read_text())["scenes"]
    if any(s not in base for s in RACE + HELD):
        return "FAIL", "baseline.json lacks scenes"
    return "PASS", f"both run on {len(RACE)} race scenes (+{len(HELD)} held-out), frames inked, baseline at {first[-1]} (mojoui/ = {BASE_REV}); docs/goals/80/race.md"


def m1():
    e, out = mojo_test("tests/test_gpu2d_cull.mojo", "gpu2d cull: ok")
    if e:
        return "FAIL", e
    return "PASS", tail("; ".join(l for l in out.splitlines() if "IDENTICAL" in l or "oracle" in l), 300)


def m2():
    e, out = mojo_test("tests/test_textfast.mojo", "textfast: ok")
    if e:
        return "FAIL", e
    m = re.search(r"STRINGS (\d+) FACES (\d+) SIZES (\d+) WEIGHTS (\d+)", out)
    if not m or int(m.group(1)) < 2000 or int(m.group(3)) < 4 or int(m.group(4)) < 2:
        return "FAIL", "corpus below GOAL.md's (≥ 2000 strings, 4 sizes, 2 weights): " + (m.group(0) if m else "no STRINGS line")
    families = [d for d in (ROOT / "fonts").iterdir() if d.is_dir()]
    if int(m.group(2)) < len(families):
        return "FAIL", f"faces tested {m.group(2)} < bundled families {len(families)} (fonts/)"
    return "PASS", m.group(0) + "; " + tail("; ".join(l for l in out.splitlines() if l.startswith("FALLBACK") or l.startswith("CACHE")), 200)


def m3():
    e, out = mojo_test("tests/test_gpu2d_waste.mojo", "gpu2d waste: ok")
    if e:
        return "FAIL", e
    o, err = race_omx()
    if err:
        return "FAIL", err
    lacking = [s for s in RACE if any(k not in o[s] for k in ("gpu_upload", "gpu_draw", "gpu_resolve"))]
    if lacking:
        return "FAIL", "race lacks the GPU split (timer queries) for " + ", ".join(lacking)
    n, err = race_nanoui()
    if not err:
        write_race(n, o)
    return "PASS", "second frame uploads/allocates nothing; GPU split in race.md"


def m4():
    e, out = mojo_test("tests/test_gpu2d_shadow.mojo", "gpu2d shadow: ok")
    if e:
        return "FAIL", e
    src = (ROOT / "mojoui" / "scene.mojo").read_text()
    if not re.search(r"def shadow\(mut self, x: Float64, y: Float64, w: Float64, h: Float64, radius: Float64, blur: Float64, color: UInt32", src):
        return "FAIL", "Painter.shadow(x, y, w, h, radius, blur, color) not in mojoui/scene.mojo"
    bench = (ROOT / "bench" / "nanoui" / "scenes.mojo").read_text()
    if bench.count(".shadow(") < 2:
        return "FAIL", "the race's boxes and dashboard don't use real shadows yet"
    r = run(["pixi", "run", "python", "scripts/components.py", "--check"], 1800)
    if r.returncode != 0:
        return "FAIL", "components matrix stale: " + tail(r.stdout + r.stderr, 200)
    return "PASS", tail("; ".join(l for l in out.splitlines() if "brute" in l or "GL vs CPU" in l), 300)


def m5():
    e, out = mojo_test("tests/test_cpu_threads.mojo", "cpu threads: ok", 7200)
    if e:
        return "FAIL", e
    ident = re.search(r"IDENTICAL (\d+)/(\d+)", out)
    sp = re.search(r"SPEEDUP ([\d.]+)", out)
    covered = re.search(r"SCENES (.*)", out)
    if not ident or ident.group(1) != ident.group(2) or int(ident.group(2)) < len(RACE) + 3:
        return "FAIL", "threaded pictures not all identical (or too few scenes): " + (ident.group(0) if ident else "no IDENTICAL line")
    if not covered or any(s not in covered.group(1) for s in RACE + ["whiteboard", "canvas", "mindmap"]):
        return "FAIL", "the test must cover every race scene and goal 75's scenes: " + (covered.group(1) if covered else "no SCENES line")
    if not sp or float(sp.group(1)) < SPEEDUP_MIN:
        return "FAIL", f"median speed-up {sp.group(1) if sp else '?'} < {SPEEDUP_MIN}"
    return "PASS", f"{ident.group(0)} bit-identical; median speed-up {sp.group(1)}×"


def m6():
    n, err = race_nanoui()
    if err:
        return "FAIL", err
    o, err = race_omx()
    if err:
        return "FAIL", err
    write_race(n, o)
    lost = []
    for s in RACE:
        for k in ("frame_med", "frame_p95", "gpu_med", "gpu_p95", "raster_med"):
            if o[s][k] > n[s][k] * TIE_MAX:
                lost.append(f"{s} {k} {o[s][k]} > {TIE_MAX}× {n[s][k]}")
    base, now, err = held_ab()  # (D-8029: was today's race run against baseline.json's recorded numbers)
    if err:
        return "FAIL", err
    for s in HELD:
        for k in ("frame_med", "gpu_med"):
            if now[s][k] > base[s][k] * HELD_MAX:
                lost.append(f"held-out {s} {k} {now[s][k]} > {HELD_MAX}× {base[s][k]}")
    def count(rev):
        cmd = ["git", "grep", "-ciE", RIVAL_WORDS] + ([rev] if rev else []) + ["--", "mojoui/"]
        return sum(int(l.rsplit(":", 1)[1]) for l in run(cmd, 120).stdout.splitlines() if l.strip())
    if count(None) > count(BASE_REV):
        lost.append(f"mojoui/ names a race scene or rival more often than at {BASE_REV} ({count(None)} > {count(BASE_REV)})")
    for t, ok in (("tests/test_gpu2d.mojo", "gpu2d cpu: ok"), ("tests/test_gpu2d_gl.mojo", "gpu2d gl: ok"), ("tests/test_gpu2d_tiles.mojo", "tiles: ok")):
        e, _ = mojo_test(t, ok)
        if e:
            lost.append(e)
    r = run(["pixi", "run", "python", "docs/goals/75-check.py", "M2", "M3", "M4", "M5", "M6"], 7200)
    bad = [l for l in r.stdout.splitlines() if re.match(r"M\d: (FAIL|BLOCKED)", l)]
    if r.returncode != 0 and not bad:
        bad = ["75-check: " + tail(r.stdout + r.stderr, 200)]
    lost += ["goal 75 " + l[:160] for l in bad]
    if lost:
        return "FAIL", "; ".join(lost)[:1500]
    return "PASS", "every race scene ≤ nanoui on frame CPU/GPU median and p95 and the CPU fallback; held-out ≤ 1.05× baseline; gpu2d tests and goal 75 M2–M6 PASS"


def m7():
    r = run(["ssh", "-i", MAC_KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", MAC_SSH, "uname -m"], 60)
    if r.returncode != 0:
        return "BLOCKED", f"the M4 can't be reached over SSH ({MAC_SSH}): {tail(r.stderr, 160)}"
    script = ROOT / "bench" / "nanoui" / "mac-race.sh"
    if not script.exists():
        return "FAIL", "bench/nanoui/mac-race.sh (builds nanoui's Metal hillclimb and scenes.mojo on Metal over SSH) missing"
    r = run(["bash", str(script)], 7200)
    if r.returncode != 0:
        return "FAIL", "mac race: " + tail(r.stdout + r.stderr, 400)
    nan, omx = {}, {}
    for line in r.stdout.splitlines():  # ("k NANOUI RESULT {…}": run k; each side's lowest of each metric, as M6)
        for side, tag in ((nan, "NANOUI RESULT "), (omx, "OMX RESULT ")):
            i = line.find(tag)
            if i >= 0:
                d = json.loads(line[i + len(tag):])
                have = side.setdefault(d["scene"], d)
                for k in d:
                    if k != "scene":
                        have[k] = min(have[k], d[k])
    if any(s not in nan or s not in omx for s in RACE):
        return "FAIL", "mac race lacks scenes: " + tail(r.stdout, 300)
    lost = [f"{s} {k} {omx[s][k]} > {nan[s][k]}" for s in RACE for k in ("frame_med", "frame_p95", "gpu_med", "gpu_p95") if omx[s][k] > nan[s][k] * TIE_MAX]
    if "gpu2d metal: ok" not in r.stdout or "metal shadow: ok" not in r.stdout:
        lost.append("test_gpu2d_metal (with the shadow cases) did not pass on the M4")
    if lost:
        return "FAIL", "; ".join(lost)[:1200]
    return "PASS", "every race scene ≤ nanoui on the M4 (Metal); test_gpu2d_metal with shadows passes"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7}

if __name__ == "__main__":
    want = [a.upper() for a in sys.argv[1:]] or list(MILESTONES)
    worst = 0
    for k in want:
        try:
            verdict, why = MILESTONES[k]()
        except Exception as x:  # a checker crash is a FAIL with its reason, never a silent pass
            verdict, why = "FAIL", f"checker error: {type(x).__name__}: {x}"
        print(f"{k}: {verdict}  {why}", flush=True)
        worst = max(worst, {"PASS": 0, "BLOCKED": 1, "FAIL": 2}[verdict])
    sys.exit(0 if worst == 0 else 1)
