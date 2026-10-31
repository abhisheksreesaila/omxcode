"""Milestone checker for docs/goals/40-GOAL.md (goal 40: Sketch, omxcode draws). Prints PASS/FAIL per milestone.

Run: pixi run python docs/goals/40-check.py        (a subset: … 40-check.py M0 M3)
Written before the work (2026-10-30), from the goal's words; never edited to make a milestone pass (add, don't weaken).
Review round 1 added proofs to M3 (D-1222): a far-off pixel count and a second session; the original proofs stand.
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

# Added after review round 1 (D-1222; the proofs above are unchanged): a second session where the strokes' layer is a
# texture before strokes are added to it and erased from it (the host's append and mend paths, D-1219, D-1220), and a
# plain scroll pans (the goal's "two-finger scroll"; GTK's `wheel:` step sends wheel notches, no modifier) while the
# zoom stays. Stroke A runs along page y = 100; after the drag the page sits at (30, 20), so the eraser crosses A at
# screen x = 230; the second stroke crosses A's box near page x = 282, where the mended pixels must still show it.
# Two notches down move the page up 80 points.
SESSION2 = [
    ("stroke:0=100,100,0.5;200,100,0.7;300,100,0.5", "strokes=1"),
    ("tap:Pan", "tool=pan"),
    ("drag:0=30,20", "pan=30,20"),
    ("tap:Pen", "tool=pen"),
    ("stroke:0=310,60,0.2;315,120,1.0;310,180,0.2", "strokes=2"),  # (crosses A's box: erasing A mends around it)
    ("stroke:0=420,150,0.9;440,250,0.5;460,350,0.1", "strokes=3"),
    ("tap:Eraser", "tool=eraser"),
    ("stroke:0=230,105,0.5;230,120,0.5;230,135,0.5", "strokes=2"),
    ("wheel:0=0,2", "pan=30,-60"),
]
MAX_OFF_PIXELS = 2  # canvas pixels more than 40 levels off the CPU render (runs give 0; a stroke missing where an
# erase was mended is ~40, a missing short stroke hundreds)


def compare(out, shot, ref_path):
    """(mean difference, pixels > 40 levels off, why not) of the window's canvas against the CPU render."""
    import numpy as np
    from PIL import Image
    box = next((l for l in out.splitlines() if l.startswith("SKETCH CANVAS:")), None)
    if not box or not shot.exists() or not ref_path.exists():
        return None, None, "no SKETCH CANVAS: line, screenshot or reference"
    x, y, w, h = (int(v) for v in box.split(":", 1)[1].split(","))
    ref = np.asarray(Image.open(ref_path).convert("L"), dtype=float)
    win = np.asarray(Image.open(shot).convert("L"), dtype=float)
    if ref.shape != (h, w) or ref.std() < 2:
        return None, None, f"reference {ref.shape[::-1]} vs canvas {w}×{h}, or blank"
    d = abs(win[y:y + h, x:x + w] - ref)
    return d.mean(), int((d > 40).sum()), ""


def in_order(out, session):
    reports = [l for l in out.splitlines() if l.startswith("SKETCH:")]
    at = 0
    for step, want in session:
        while at < len(reports) and want not in reports[at]:
            at += 1
        if at == len(reports):
            return reports, f"after {step}: no SKETCH: line with {want!r} (lines: {reports[-4:]})"
    return reports, ""


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
    # Added proofs (D-1222): one missing stroke barely moves a mean, so count the pixels far off too; then SESSION2.
    _, off, why = compare(out, shot, OUT / "sketch-ref.png")
    if why or off > MAX_OFF_PIXELS:
        return False, why or f"{off} canvas pixels differ by > 40 levels (≤ {MAX_OFF_PIXELS})"
    shot2 = OUT / "sketch-gtk-2.png"
    ref2 = OUT / "sketch-ref-2.png"
    code2, out2 = gtk_session(["pause:500"] + [s for s, _ in SESSION2] + ["render:0=" + str(ref2)], shot2)
    reports2, why = in_order(out2, SESSION2)
    if code2 != 0 or why:
        return False, f"session 2: exit {code2}; {why}"
    if "zoom=1.00" not in reports2[-1] or "strokes=2" not in reports2[-1]:
        return False, f"session 2's final state is wrong: {reports2[-1]!r} (a scroll must pan, not zoom)"
    diff2, off2, why = compare(out2, shot2, ref2)
    if why or diff2 > 8 or off2 > MAX_OFF_PIXELS:
        return False, why or f"session 2: GTK vs CPU {diff2:.1f} levels (≤ 8), {off2} pixels > 40 off (≤ {MAX_OFF_PIXELS})"
    return True, (f"{len(SESSION)} steps as expected ({reports[-1]}); GTK vs CPU {diff:.1f} levels, {off} pixels > 40 off; "
                  f"session 2 (texture, append, erase, scroll pans): {reports2[-1]}, {diff2:.1f} levels, {off2} pixels; web and mac built")


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
    # (addition, probe fixes D-1707: erasing was 14-23 ms p95, the whole ink layer built again per erased stroke; now
    # the kept strokes' nodes are reused and only the erased box is drawn again)
    erase = b.get("erase", {})
    if erase.get("p95_ms") is None or erase["p95_ms"] > 16.7:
        problems.append(f"erase p95 {erase.get('p95_ms')} ms (≤ 16.7)")
    if erase.get("ink_layer_rebuilds", 1) != 0 or erase.get("trimmed_by_layer", {}).get("ink", 0) == 0:
        problems.append(f"erasing built the ink layer again {erase.get('ink_layer_rebuilds')} times (trimmed {erase.get('trimmed_by_layer')})")
    if not b.get("renderer"):
        problems.append("renderer not recorded")
    if problems:
        return False, "; ".join(problems)
    return True, (f"{b['strokes']} strokes, {b['points']} points on {b['renderer']}: p95 pan {b['pan']['p95_ms']}, "
                  f"zoom {b['zoom']['p95_ms']}, draw {b['draw']['p95_ms']}, erase {b['erase']['p95_ms']} ms; ink layer kept")


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
