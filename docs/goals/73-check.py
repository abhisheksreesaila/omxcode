"""Goal 73's proof: links you type with help, a Board that grows, cards with depth (docs/goals/73.md).
Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/73-check.py [M1 M2 ...]          (default: every milestone)

Each milestone's proof lives in docs/goals/73/m<n>.py as `check() -> (ok, why)` (ok None: BLOCKED), so the milestones can be
built in parallel worktrees without touching one file. Outputs under build/g73.
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g73"
HERE = ROOT / "docs/goals/73"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def milestone(n):
    def run():
        path = HERE / f"m{n}.py"
        if not path.exists():
            return None, f"{path.relative_to(ROOT)} not written yet"
        return _load(f"g73m{n}", path).check()
    return run


def m4():
    """Nothing regressed: goal 71's M5 (goal 70's M3, goal 68's and goal 47's inside it), plus docs/goals/73/m4.py's extras."""
    g71 = _load("g71check", ROOT / "docs/goals/71-check.py")
    ok, why = g71.m5()
    if not ok:
        return ok, "goal 71 M5: " + why
    extra = HERE / "m4.py"
    if extra.exists():
        ok2, why2 = _load("g73m4", extra).check()
        return ok2, why + "; " + why2
    return ok, why


MILESTONES = {"M1": milestone(1), "M2": milestone(2), "M3": milestone(3), "M4": m4}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    picked = sys.argv[1:] or list(MILESTONES)
    failed = False
    for name in picked:
        try:
            ok, why = MILESTONES[name]()
        except Exception as e:  # noqa: BLE001 (a crash is a FAIL with its reason)
            import traceback

            traceback.print_exc()
            ok, why = False, f"{type(e).__name__}: {e}"
        word = "PASS" if ok else ("BLOCKED" if ok is None else "FAIL")
        failed |= ok is False
        print(f"{name}: {word}  {why}", flush=True)
    sys.exit(1 if failed else 0)
