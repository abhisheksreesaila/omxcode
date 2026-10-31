"""The GTK host's gaps: step sees a frozen UI thread, both ways it measures (D-1309, D-1324).

examples/fieldcheck with FIELDCHECK_STALL_MS=300 holds the UI thread 300 ms on a change. Untraced, gaps: asks for a
frame every frame (Jot's M2); under MOJOUI_TRACE (goal 30's runs) it times the app's own paints. Either way the longest
gap must cover the stall, and without a stall stay short.
Run: pixi run python tests/test_gaps_stall.py   (after tests/test_field_queue.py has built fieldcheck)
"""
import os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))


def longest(stall, traced):
    env = dict(os.environ, MOJOUI_TEST="pause:300;gaps:start;pause:200;type:Query=abc;gaps:1200")
    if stall:
        env["FIELDCHECK_STALL_MS"] = str(stall)
    if traced:
        env["MOJOUI_TRACE"] = "1"
    r = subprocess.run([str(ROOT / "build/fieldcheck/linux/fieldcheck")], env=env, capture_output=True, text=True, timeout=120)
    m = re.search(r"GAPS: (\d+) frames, longest ([\d.]+) ms", r.stdout)
    return float(m.group(2)) if m else None


def main():
    import headless
    headless.ensure()
    bad = []
    for traced in (False, True):
        frozen, calm = longest(300, traced), longest(0, traced)
        mode = "traced" if traced else "untraced"
        print(f"{mode}: a 300 ms stall reads {frozen} ms; no stall {calm} ms")
        if frozen is None or frozen < 280:
            bad.append(f"{mode}: the stall wasn't seen ({frozen})")
        if calm is None or (not traced and calm > 100):
            bad.append(f"{mode}: without a stall {calm} ms")
    print("gaps stall: " + ("FAIL " + "; ".join(bad) if bad else "ok"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
