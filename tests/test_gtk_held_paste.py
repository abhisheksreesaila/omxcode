"""Goal 82 integration (the merge-79-81 review, D-8906): what comes while a FULL rebuild waits on GTK is held, not dropped:
(b) the pointer leaving a Canvas(hover=True) (canvas_hover returned on node -1 before its busy test), and
(c) Ctrl+V's paste (the node read -1, so the clipboard was never read and only the key arrived).

goal 81's input app (tests/gtkapps/input, G82_HOVER=1: hover and takes_paste on) rebuilds its whole window every eleventh
event. Each burst is "a" then the canvas's item; the burst step prints "BURST: full <item>" when an item goes while a full
rebuild waits. Every burst must reach update() whole: A, then for "v" the key v and one PASTE with the clipboard's words,
for "l" one HOVER. Bars: nothing lost or twice, and at least 4 of each kind sent during a full wait.
Run: pixi run python tests/test_gtk_held_paste.py [--no-build]
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts"))
from test_gtk_random import OUT, build

EXE = OUT / "input" / "input"
VIEW = (ROOT / "mojoui/view.mojo").read_text()
KEY, HOVER, PASTE = (int(re.search(rf"^comptime {n} = (\d+)", VIEW, re.M)[1]) for n in ("KEY", "HOVER", "PASTE"))
CANVAS, A = 19, 1
CLIP = "held words"


def main():
    if "--no-build" not in sys.argv:
        e = build("input", EXE)
        if e:
            print("gtk_held_paste: FAIL (build)", e)
            return 1
    import headless
    headless.ensure()
    log = OUT / "held-paste.log"
    log.unlink(missing_ok=True)
    kinds = ["v", "l"] * 80  # (5 updates a pair: both kinds meet every eleventh, a full rebuild)
    steps = [f"clipboard:{CLIP}"]
    for k in kinds:
        steps += [f"burst:a~canvas={k}", "pause:120", f"logmark:{log}"]  # (the paste's clipboard read lands within the pause)
    env = dict(os.environ, MOJOUI_TEST=";".join(steps), G81_LOG=str(log), MOJOUI_WINDOW="1000x800", G82_HOVER="1")
    r = subprocess.run([str(EXE)], capture_output=True, text=True, timeout=300, env=env)
    said = r.stdout + r.stderr
    full = re.findall(r"^BURST: full (\S+)", said, re.M)
    parts = (log.read_text() if log.exists() else "").split("MARK\n")
    lost = twice = 0
    shown = 0
    for k, part in zip(kinds, parts):
        got = [tuple(line.split("\t")) for line in part.splitlines()]
        heard = [(int(g[0]), g[1] if int(g[2]) == PASTE or (int(g[0]) == CANVAS and int(g[2]) == KEY) else "", int(g[2]) if int(g[0]) == CANVAS else 0) for g in got]
        want = [(A, "", 0)] + ([(CANVAS, "v", KEY), (CANVAS, CLIP, PASTE)] if k == "v" else [(CANVAS, "", HOVER)])
        miss = [w for w in want if heard.count(w) < 1]
        more = [h for h in heard if h in want and heard.count(h) > 1]
        lost += len(miss)
        twice += len(set(more))
        if (miss or more) and shown < 6:
            shown += 1
            print(f"  burst a~canvas={k}: heard {heard}, missing {miss}, twice {sorted(set(more))}")
    bad = r.returncode != 0 or "CRITICAL" in r.stderr or len(parts) != len(kinds) + 1
    if bad:
        print(f"  exit {r.returncode}; {len(parts) - 1} bursts logged of {len(kinds)}; {[x for x in said.splitlines() if 'TEST:' in x or 'CRITICAL' in x][:4]}")
    print("FACT bursts", len(kinds))
    print("FACT full_paste", full.count("v"))
    print("FACT full_leave", full.count("l"))
    print("FACT lost", lost)
    print("FACT twice", twice)
    ok = not bad and lost == 0 and twice == 0 and full.count("v") >= 4 and full.count("l") >= 4
    print("gtk_held_paste: ok" if ok else "gtk_held_paste: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
