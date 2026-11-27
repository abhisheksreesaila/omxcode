"""Milestone checker for goal 82 (docs/goals/82-draft.md): pnote at the web app's parity. Prints "Mn: PASS|FAIL|BLOCKED  why".

    scripts/check 82 [M1 … M7 TYPING INTEG M5.engine …]          (pixi run python docs/goals/82-check.py …)

Three workers wrote the milestones in parallel; the integration (D-8900) keeps each worker's checker whole, unedited, as a module
of its own (their helpers share names with different signatures), and this file only dispatches:
  docs/goals/82/check_a.py  M1 focus mode, M2 pictures, M4 print and export, TYPING (worker A)
  docs/goals/82/check_b.py  M3 import and export, M7 live updates and deletion merge (worker B)
  docs/goals/82/check_c.py  M5 voice, M6 AI (worker C)
  docs/goals/82/check_i.py  INTEG: the integration's own checks (one drop target, the merged media store, the review fixes);
                            TYPING_MAC(_BEFORE): Mac typing before and after the CoreText cluster fix
Each module keeps its own locking (the quiet lock shared per command or per run, the build lock per Mojo build, the Mac lock).
"""
import importlib.util
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent / "82"


def load(name):
    spec = importlib.util.spec_from_file_location(f"g82_{name}", HERE / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


OWNER = {"M1": "check_a", "M2": "check_a", "M4": "check_a", "TYPING": "check_a", "M3": "check_b", "M7": "check_b",
         "M5": "check_c", "M6": "check_c", "INTEG": "check_i", "TYPING_MAC": "check_i", "TYPING_MAC_BEFORE": "check_i"}


def table(mod):
    return getattr(mod, "CHECKS", None) or getattr(mod, "ALL", None) or getattr(mod, "MILESTONES")


if __name__ == "__main__":
    want = sys.argv[1:] or ["M1", "M2", "M3", "M4", "M5", "M6", "M7", "INTEG"]
    mods, bad = {}, False
    for k in want:
        part = None
        if "." in k:  # M5.engine: one part of a milestone (worker C's checker names its parts m5_engine…)
            k, part = k.split(".", 1)
        if k not in OWNER:
            print(f"{k}: BLOCKED  no such milestone (have {' '.join(OWNER)})", flush=True)
            continue
        if not (HERE / f"{OWNER[k]}.py").exists():
            print(f"{k}: BLOCKED  {OWNER[k]}.py is missing", flush=True)
            continue
        mod = mods.get(OWNER[k]) or mods.setdefault(OWNER[k], load(OWNER[k]))
        mod.OUT.mkdir(parents=True, exist_ok=True)
        try:
            if part:
                g = getattr(mod, f"{k.lower()}_{part}", None)
                verdict, why = g() if g else ("FAIL", f"no part {part} in {OWNER[k]}")
            else:
                verdict, why = table(mod)[k]()
        except Exception as e:
            import traceback
            traceback.print_exc()
            nf = getattr(mod, "NotFree", None)
            if nf is not None and isinstance(e, nf):
                verdict, why = "BLOCKED", f"the machine wasn't free for a GPU window ({e}); run again when it is"
            else:
                verdict, why = "FAIL", f"{type(e).__name__}: {e}"
        print(f"{k}: {verdict}  {why}", flush=True)
        bad = bad or verdict == "FAIL"
    sys.exit(1 if bad else 0)
