"""Goal 78's proof: a free canvas, live resizing, keys, and video you can see (docs/goals/78.md).
Prints "Mn: PASS|FAIL|BLOCKED  why".

    pixi run python docs/goals/78-check.py [M1 M2 ...]          (default: every milestone)

Each milestone's proof lives in docs/goals/78/m<n>.py as `check() -> (ok, why)` (ok None: BLOCKED); docs/goals/78/common.py
holds what they share (omxplorer on the private display, the web host, the parsers). Outputs under build/g78.
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/g78"
HERE = ROOT / "docs/goals/78"


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
        return _load(f"g78m{n}", path).check()
    return run


MILESTONES = {"M1": milestone(1), "M2": milestone(2), "M3": milestone(3), "M4": milestone(4)}

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
