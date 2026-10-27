"""Milestone checker for GOAL.md (goal 34: first-class JS; goal 33's M1, M2, M4, M5 run as M4: the full chain waits
for the next stable point, owner 2026-10-27). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M1; earlier goals: through docs/goals/NN-check.py)
Each milestone's proof is written before its work starts (todo() until then: it fails), from GOAL.md's words.
"""

import importlib.util
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g33 = load("goal33", "docs/goals/33-check.py")


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m4():
    """Nothing regressed (minimal, owner): goal 33's M1, M2, M4, M5."""
    problems = []
    for name in ("m1", "m2", "m4", "m5"):
        ok, msg = getattr(g33, name)()
        if not ok:
            problems.append(f"33-{name.upper()}: {msg}")
    return not problems, "; ".join(problems) or "goal 33's M1, M2, M4, M5 pass"


MILESTONES = [
    ("M0", todo("WebComponent, web_assets, defineWidget, examples/widgets on the web (GOAL.md M0)")),
    ("M1", todo("npm + TypeScript via esbuild, CodeMirror in examples/widgets, new_widget.sh, docs/js.md (GOAL.md M1)")),
    ("M2", todo("CSP, hashed assets, the asset lint, sandboxed WebFrame (GOAL.md M2)")),
    ("M3", todo("the widget in a WebKitGTK view on GTK (GOAL.md M3)")),
    ("M4", m4),
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
