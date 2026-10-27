"""Milestone checker for GOAL.md (goal 34b: JS widgets everywhere, and agents see them; goal 34's M0–M3 and goal 33's
M1, M4 run as M3, minimal regression by the owner's choice). Prints PASS/FAIL per milestone.

Run: scripts/check   (a subset: scripts/check M0 M1)
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


g34 = load("goal34", "docs/goals/34-check.py")
g33 = g34.g33


def todo(what):
    def fn():
        return False, f"not built yet: {what}"
    return fn


def m3():
    """Nothing regressed (minimal, owner): goal 34's M0–M3, goal 33's M1 and M4."""
    problems = []
    for label, fn in [("34-M0", g34.m0), ("34-M1", g34.m1), ("34-M2", g34.m2), ("34-M3", g34.m3), ("33-M1", g33.m1), ("33-M4", g33.m4)]:
        ok, msg = fn()
        if not ok:
            problems.append(f"{label}: {msg}")
    return not problems, "; ".join(problems) or "goal 34's M0–M3 and goal 33's M1, M4 pass"


MILESTONES = [
    ("M0", todo("agents see JS widgets: describe(), settable fields, the agent host's tools (GOAL.md M0)")),
    ("M1", todo("ECharts from npm with no host changes (GOAL.md M1)")),
    ("M2", todo("WKWebView on the Mac via mac-ci (GOAL.md M2)")),
    ("M3", m3),
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
