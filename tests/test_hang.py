"""Goal 81, M5: the hang monitor. A real GTK app (tests/gtkapps/hang; headless, not in test mode: the monitor is on by
itself) hangs 1.2 s in update(): the monitor says so during the hang and after it, with the message; a 0.1 s one isn't
said; nothing of the app's words, title or paths is in what it writes; hangs.log keeps at most 200 lines; off is off.
Run: pixi run python tests/test_hang.py [--no-build]
"""
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts"))
from test_gtk_random import OUT, build

EXE = OUT / "hang" / "hang"
STATE = OUT / "hang-state"
PRIVATE = ["secret", "typed", "Private", "diary", "/home/", "someone", "hint"]


def go(env, seconds):
    """The app for `seconds`, its lines with when each came; then it's ended."""
    p = subprocess.Popen([str(EXE)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=dict(os.environ, MOJOUI_STATE=str(STATE), **env))
    lines = []
    t = threading.Thread(target=lambda: [lines.append((time.monotonic(), x.rstrip())) for x in p.stdout])
    t.start()
    time.sleep(seconds)
    alive = p.poll() is None
    p.terminate()
    p.wait(10)
    t.join(5)
    return lines, alive


def main():
    if "--no-build" not in sys.argv:
        e = build("hang", EXE)
        if e:
            print("hang: FAIL (build)", e)
            return 1
    import headless
    headless.ensure()
    for k in ("MOJOUI_TEST", "MOJOUI_HANGS", "MOJOUI_HANGS_MS"):
        os.environ.pop(k, None)
    shutil.rmtree(STATE, ignore_errors=True)
    STATE.mkdir(parents=True)
    (STATE / "hangs.log").write_text("".join(f"2026-01-01T00:00:00Z old line {k}\n" for k in range(300)))
    lines, alive = go({}, 8)
    at = {x: t for t, x in lines}
    start, stop = at.get("HANGING"), at.get("DONE HANGING")
    said = [(t, x) for t, x in lines if x.startswith("HANG: ")]
    during = [x for t, x in said if start and stop and start < t < stop + 0.02 and "counting" in x]
    after = [x for t, x in said if stop and t >= stop - 0.02 and "ended after" in x]
    log = (STATE / "hangs.log").read_text().splitlines()
    new = [x for x in log if "old line" not in x]
    ms = int(re.search(r"ended after (\d+) ms", after[0])[1]) if after else 0
    named = bool(during and after and "update msg=77" in during[0] and "update msg=77" in after[0] and 1150 <= ms <= 1600)
    off, _ = go({"MOJOUI_HANGS": "0"}, 5)
    r = subprocess.run(["pixi", "run", "mojo", "run", "-O3", "-I", ".", "-I", "vendor", "tests/test_hangmarks.mojo"], cwd=ROOT, capture_output=True, text=True)
    cost = re.search(r"FACT mark_us (\S+)", r.stdout)
    private = [x for x in new + [x for _, x in said] if any(w in x for w in PRIVATE)]
    print("FACT during", 1 if len(during) == 1 else 0)
    print("FACT after", 1 if len(after) == 1 else 0)
    print("FACT named", 1 if named else 0)
    print("FACT short_said", len(said) - len(during) - len(after))
    print("FACT mark_us", cost[1] if cost else "nan")
    print("FACT private", len(private))
    print("FACT log_lines_max", len(log))
    print("FACT off_said", len([x for _, x in off if x.startswith("HANG: ")]))
    for _, x in said:
        print("  " + x)
    ok = alive and len(during) == 1 and len(after) == 1 and named and len(said) == 2 and not private and len(log) <= 200 and len(new) == 2 and r.returncode == 0
    ok = ok and any(x == "HANGING" for _, x in off) and not any(x.startswith("HANG: ") for _, x in off)
    print("hang: ok" if ok else "hang: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
