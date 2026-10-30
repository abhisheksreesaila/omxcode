"""Milestone checker for docs/goals/40-GOAL.md (goal 40: Sketch, omxcode draws). Prints PASS/FAIL per milestone.

Run: pixi run python docs/goals/40-check.py        (a subset: … 40-check.py M0 M3)
Written before the work (2026-10-30), from the goal's words; never edited to make a milestone pass (add, don't weaken).
GTK runs are headless (scripts/headless.py, as scripts/check does).
"""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "pixi.toml").exists())
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "docs" / "goals" / "40"
APP = ROOT / "build" / "sketch"

# The scripted session M3 runs (steps the GTK host understands; `stroke:` is M2's new step, `render:` M3's) and, for
# each, what the app's `SKETCH:` line (printed on every change of its state) must say next. Canvas 0 draws.
SESSION = [
    ("stroke:0=100,100,0.2;140,110,0.5;180,130,0.9;220,160,1.0", "strokes=1"),
    ("stroke:0=100,300,0.6;200,300,0.6;300,300,0.6", "strokes=2"),
    ("stroke:0=400,200,1.0;420,260,0.4;440,320,0.1", "strokes=3"),
    ("key:0=ctrl+z", "strokes=2"),
    ("zoom:0=2", "zoom=2.00"),
    ("tap:Pan", "tool=pan"),
    ("drag:0=-60,-40", "pan="),  # (checked below: not pan=0,0)
]
PRESSURES = [0.2, 0.5, 0.9, 1.0]


def run(cmd, timeout=3600, env=None):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=env)


def mojo_test(path, ok_lines):
    if not (ROOT / path).exists():
        return False, f"{path} missing"
    r = run(["pixi", "run", "mojo", "run", "-I", ".", path], 1800)
    out = r.stdout + r.stderr
    missing = [l for l in ok_lines if l not in out]
    if r.returncode != 0 or missing:
        errs = " | ".join(l for l in out.splitlines() if "error" in l.lower() or "FAIL" in l)[-500:]
        return False, f"{path}: exit {r.returncode}, missing {missing} {errs}"
    return True, f"{path}: " + ", ".join(ok_lines)


def build(target):
    r = run(["scripts/build.sh", "sketch", target], 3600)
    return r.returncode == 0, (r.stdout + r.stderr)[-400:]


def gtk_session(steps, shot=None):
    import headless
    headless.ensure()
    env = dict(os.environ, MOJOUI_TEST=";".join(steps))
    if shot:
        env["MOJOUI_SHOT"] = str(shot)
    r = run([str(APP / "linux" / "sketch")], 600, env=env)
    return r.returncode, r.stdout + r.stderr


def m0():
    return mojo_test("tests/test_ink.mojo", ["ink outline: ok", "ink pressure: ok", "ink smooth: ok", "ink hit: ok"])


def m1():
    ok, msg = mojo_test("tests/test_scene_polygon.mojo", ["polygon cpu: ok", "polygon scene: ok", "layer transform: ok"])
    if not ok:
        return ok, msg
    gtk = (ROOT / "mojoui" / "hosts" / "gtk.mojo").read_text()
    if "gtk_snapshot_append_fill" not in gtk or "gtk_snapshot_scale" not in gtk:
        return False, "GTK doesn't replay the polygon as a path fill or the layer transform as a snapshot scale"
    return True, msg + "; GTK replays both"


def m2():
    ok, why = build("linux")
    if not ok:
        return False, "linux build failed: " + why
    code, out = gtk_session(["pause:500", SESSION[0][0]])
    got = [float(l.split(":", 1)[1]) for l in out.splitlines() if l.startswith("SKETCH PRESSURE:")]
    if code != 0 or [round(p, 3) for p in got] != PRESSURES:
        return False, f"exit {code}; pressures {got}, want {PRESSURES}"
    src = (ROOT / "mojoui" / "app.mojo").read_text()
    if "pressure" not in src:
        return False, "Event has no pressure field"
    return True, f"GTK: pressures {got} reached the app"


def m3():
    for target in ("linux", "web", "mac"):
        ok, why = build(target)
        if not ok:
            return False, f"{target} build failed: {why}"
    OUT.mkdir(parents=True, exist_ok=True)
    shot = OUT / "sketch-gtk.png"
    steps = ["pause:500"]
    steps += [step for step, _ in SESSION]
    steps.append("render:0=" + str(OUT / "sketch-ref.png"))  # the host paints canvas 0 with a SurfacePainter (generic step)
    code, out = gtk_session(steps, shot)
    reports = [l for l in out.splitlines() if l.startswith("SKETCH:")]
    if code != 0 or not reports:
        return False, f"exit {code}; no SKETCH: lines: {out[-400:]}"
    at = 0  # each step's expectation must appear, in order
    for step, want in SESSION:
        while at < len(reports) and want not in reports[at]:
            at += 1
        if at == len(reports):
            return False, f"after {step}: no SKETCH: line with {want!r} (lines: {reports[-4:]})"
    if "pan=0,0" in reports[-1] or "strokes=2" not in reports[-1] or "zoom=2.00" not in reports[-1]:
        return False, f"the final state is wrong: {reports[-1]!r} (want strokes=2, zoom=2.00, a pan that moved)"
    if not shot.exists() or not (OUT / "sketch-ref.png").exists():
        return False, "screenshot or reference render missing"
    import numpy as np
    from PIL import Image
    ref = np.asarray(Image.open(OUT / "sketch-ref.png").convert("L"), dtype=float)
    win = np.asarray(Image.open(shot).convert("L"), dtype=float)
    box = next((l for l in out.splitlines() if l.startswith("SKETCH CANVAS:")), None)  # x,y,w,h of the canvas in the window
    if not box:
        return False, "no SKETCH CANVAS: line (where the canvas sits in the window)"
    x, y, w, h = (int(v) for v in box.split(":", 1)[1].split(","))
    if ref.shape != (h, w):
        return False, f"reference {ref.shape[::-1]} ≠ canvas {w}×{h}"
    if ref.std() < 2:
        return False, "the reference render is blank"
    diff = abs(win[y:y + h, x:x + w] - ref).mean()
    if diff > 8:
        return False, f"GTK's canvas differs from the CPU render by {diff:.1f} levels (≤ 8)"
    return True, f"{len(SESSION)} steps as expected ({reports[-1]}); GTK vs CPU {diff:.1f} levels; web and mac built"


def m4():
    path = OUT / "bench.json"
    if not path.exists():
        return False, "docs/goals/40/bench.json missing (scripts/sketch_bench.py)"
    b = json.loads(path.read_text())
    srcs = ["mojoui/ink.mojo", "mojoui/scene.mojo", "mojoui/hosts/gtk.mojo", "examples/sketch"]
    stale = run(["git", "diff", "--quiet", b.get("commit", "none"), "HEAD", "--", *srcs]).returncode != 0
    dirty = run(["git", "diff", "--quiet", "HEAD", "--", *srcs]).returncode != 0
    if stale or dirty:
        return False, f"bench.json is stale for {srcs} (commit {b.get('commit')})"
    problems = []
    if b.get("strokes", 0) < 1000 or b.get("points", 0) < 100_000:
        problems.append(f"too small: {b.get('strokes')} strokes, {b.get('points')} points")
    for phase in ("pan", "zoom", "draw"):
        p95 = b.get(phase, {}).get("p95_ms")
        if p95 is None or p95 > 16.7:
            problems.append(f"{phase} p95 {p95} ms (≤ 16.7)")
    for phase in ("pan", "zoom"):
        if b.get(phase, {}).get("ink_layer_rebuilds", 1) != 0:
            problems.append(f"the ink layer was rebuilt during {phase}")
    if not b.get("renderer"):
        problems.append("renderer not recorded")
    if problems:
        return False, "; ".join(problems)
    return True, (f"{b['strokes']} strokes, {b['points']} points on {b['renderer']}: p95 pan {b['pan']['p95_ms']}, "
                  f"zoom {b['zoom']['p95_ms']}, draw {b['draw']['p95_ms']} ms; ink layer kept")


def m5():
    problems = []
    page = (ROOT / "docs" / "gallery" / "index.html").read_text()
    if "Drawing" not in page:
        problems.append("no Drawing section in the gallery")
    from PIL import Image
    import numpy as np
    for name in ("sketch-gtk.png", "sketch-web.png"):
        p = ROOT / "docs" / "gallery" / "img" / name
        if f"img/{name}" not in page:
            problems.append(f"the gallery doesn't show {name}")
        if not p.exists():
            problems.append(f"{name} missing")
        elif np.asarray(Image.open(p).convert("L"), dtype=float).std() < 2:
            problems.append(f"{name} is blank")
    if run(["pixi", "run", "python", "scripts/components.py", "--check"]).returncode != 0:
        problems.append("docs/components.md is stale")
    comps = (ROOT / "docs" / "components.md").read_text().lower()
    for word in ("ink stroke", "polygon", "layer transform", "pressure"):
        if word not in comps:
            problems.append(f"docs/components.md doesn't list {word}")
    if "mojoui.ink" not in (ROOT / "docs" / "llms.txt").read_text():
        problems.append("docs/llms.txt doesn't name mojoui.ink")
    top = (ROOT / "EXPERIMENTS.md").read_text().split("\n## ", 2)
    if len(top) < 2 or "40" not in top[1].splitlines()[0]:
        problems.append("EXPERIMENTS.md's newest entry isn't goal 40")
    if problems:
        return False, "; ".join(problems)
    return True, "gallery Drawing section, matrix, llms.txt and EXPERIMENTS updated"


MILESTONES = {"M0": m0, "M1": m1, "M2": m2, "M3": m3, "M4": m4, "M5": m5}

if __name__ == "__main__":
    pick = [a for a in sys.argv[1:] if a in MILESTONES] or list(MILESTONES)
    failed = 0
    for name in pick:
        try:
            ok, msg = MILESTONES[name]()
        except Exception as e:  # a crash in a proof is a FAIL, not a pass
            ok, msg = False, f"{type(e).__name__}: {e}"
        failed += not ok
        print(f"{name} {'PASS' if ok else 'FAIL'}: {msg}", flush=True)
    sys.exit(1 if failed else 0)
