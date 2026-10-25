"""Milestone checker for GOAL.md (goal 33: OMX Console rebuilt in omxcode; goal 32's passing M0–M2 and goal 30's
M0–M5 run as M8, every earlier goal's inside them). Rebuilds from scratch, prints PASS/FAIL per milestone.

Run: scripts/check   (a subset without rebuilding: scripts/check M0 M1; earlier goals: through docs/goals/NN-check.py)
Each milestone's proof is written before its work starts (todo() until then: it fails), from GOAL.md's words.
The original console is read from MXCONSOLE_DIR (default ~/Projects/mxstudio/mxconsole/console), never written.
"""

import importlib.util
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
OUT = ROOT / "docs" / "goals" / "33"
FIXTURES = OUT / "fixtures"
MXCONSOLE_DIR = Path(os.environ.get("MXCONSOLE_DIR", Path.home() / "Projects/mxstudio/mxconsole/console"))
SIZES = [(1440, 900), (390, 844)]
SCREENS = ["models", "overview", "bench", "logs", "notebook", "add", "keys", "gateway", "security", "settings"]
POLLED = ["/admin/models", "/admin/metrics", "/admin/series", "/admin/requests", "/admin/info", "/admin/system",
          "/admin/pulls", "/admin/ports"]  # what the console asks every 0.7–15 s (core.js, system-data.js, beacon.js)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g32 = load("goal32", "docs/goals/32-check.py")
g30 = g32.g30


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m0():
    """The measure: recorded replies, the original's ten screens at two sizes, twice, and the noise floor."""
    problems = []
    if not (MXCONSOLE_DIR / "index.html").exists():
        return False, f"no original console at {MXCONSOLE_DIR} (set MXCONSOLE_DIR)"
    for path in POLLED:
        if not list(FIXTURES.glob(path.strip("/").replace("/", "_") + "*.json")):
            problems.append(f"no recorded reply for {path} in {FIXTURES.relative_to(ROOT)}")
    try:
        import console_side
    except ImportError as e:
        return False, f"scripts/console_side.py missing: {e}"
    if [s for s, _ in console_side.SCREENS] != SCREENS or list(console_side.SIZES) != SIZES:
        problems.append(f"console_side shoots {console_side.SCREENS} at {console_side.SIZES}, not GOAL.md's ten at {SIZES}")
    runs = []
    for run_id in ("a", "b"):
        shots, misses = console_side.shoot_original(run_id)  # {(screen, (w, h)): png path}, [paths not in the fixtures]
        if misses:
            problems.append(f"run {run_id}: the console asked for paths the fixtures don't hold: {sorted(set(misses))[:8]}")
        want = {(s, size) for s in SCREENS for size in SIZES}
        if set(shots) != want:
            problems.append(f"run {run_id} is missing {sorted(want - set(shots))[:6]}")
        runs.append(shots)
    if problems:
        return False, "; ".join(problems)
    floor = 0.0
    for key in runs[0]:
        floor = max(floor, console_side.differing(runs[0][key], runs[1][key]))  # share of pixels that differ, 0–1
    (OUT / "floor.txt").write_text(f"{floor:.5f}\n")
    if floor > 0.01:
        return False, f"the original differs from itself by {floor:.2%} of pixels on some screen (> 1 %): the measure is too noisy"
    return True, f"20 screens shot twice from {len(list(FIXTURES.glob('*.json')))} recorded replies; noise floor {floor:.3%}"


def m8():
    """In the gallery, and nothing regressed: goal 32's M0–M2, goal 30's M0–M5 (goals 3–29 inside them)."""
    problems = []
    gallery = (ROOT / "docs" / "gallery" / "index.html").read_text()
    if "console" not in gallery.lower():
        problems.append("docs/gallery/index.html doesn't show the console")
    for host in ("gtk", "web", "mac"):
        if not list((ROOT / "docs" / "gallery" / "img").glob(f"console*{host}*")):
            problems.append(f"no console shot from {host} in docs/gallery/img")
    for name, fn in [("32-M0", g32.m0), ("32-M1", g32.m1), ("32-M2", g32.m2), ("32-M7", g32.m7)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{name}: {msg}")
    return not problems, "; ".join(problems) or "in the gallery; goal 32's M0–M2 and goal 30's M0–M5 pass"


MILESTONES = [
    ("M0", m0),
    ("M1", todo("mojoui/http.mojo, tests/test_http.mojo, examples/httpcheck (GOAL.md M1)")),
    ("M2", todo("App.every, json.mojo over the recorded replies (GOAL.md M2)")),
    ("M3", todo("themes/omxqua.mojo, a Look from omxqua's tokens (GOAL.md M3)")),
    ("M4", todo("the console's components in mojoui/ (GOAL.md M4)")),
    ("M5", todo("examples/console: My models and the model page (GOAL.md M5)")),
    ("M6", todo("examples/console: Add, Keys, Gateway, Security, Settings (GOAL.md M6)")),
    ("M7", todo("identical: web ≥ 99 % of pixels, GTK and Mac boxes, a live daemon (GOAL.md M7)")),
    ("M8", m8),
]


def main():
    import headless
    headless.ensure()
    only = sys.argv[1:]
    if not only:
        g30.build_all()
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
