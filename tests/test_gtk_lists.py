"""Goal 81, M3: several LazyLists in one window keep updating, scrolled or not (the study's F1: once one was scrolled,
the others kept their old rows). Every row's words are read from the row widgets. Headless (Xvfb).
Run: pixi run python tests/test_gtk_lists.py [--no-build]
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

EXE = OUT / "lists" / "lists"
READ = "pause:300;rows:0;rows:1"
READ3 = READ + ";rows:2"
# (steps, then per read: the word each row must show)
RUNS = [
    ("both at the top", f"tap:Flip;{READ};tap:Again;{READ}", ["new", "newer"], 2),
    ("the second at 500", f"pause:300;scroll:1=500;pause:600;{READ};tap:Flip;{READ};tap:Again;{READ}", ["old", "new", "newer"], 2),
    ("both scrolled apart", f"pause:300;scroll:0=200;scroll:1=700;pause:600;{READ};tap:Flip;{READ};tap:Again;{READ}", ["old", "new", "newer"], 2),
    ("a third one, taken away and back", f"pause:300;tap:Third;pause:300;scroll:2=500;pause:600;{READ3};tap:Flip;{READ3};tap:Third;pause:300;{READ};tap:Again;{READ};tap:Third;{READ3}", ["old", "new", "new", "newer", "newer"], 0),
    ("one gets shorter", f"pause:300;scroll:1=500;pause:600;tap:Fewer;{READ};tap:Flip;{READ}", ["old", "new"], 2),
]


def main():
    if "--no-build" not in sys.argv:
        e = build("lists", EXE)
        if e:
            print("gtk_lists: FAIL (build)", e)
            return 1
    import headless
    headless.ensure()
    rows = stale = moved = runs = 0
    for name, steps, words, _ in RUNS:
        env = dict(os.environ, MOJOUI_TEST=steps, MOJOUI_SHOT=str(OUT / "lists.png"))
        r = subprocess.run([str(EXE)], capture_output=True, text=True, timeout=120, env=env)
        reads = re.findall(r"^ROWS: (\d+) at (-?\d+) (.*)$", r.stdout, re.M)
        want = []  # (the word expected at each read line: a read is as many lines as it has lists)
        for word, step in zip(words, re.findall(r"((?:rows:\d;?)+)", steps)):
            want += [word] * step.count("rows")
        if r.returncode != 0 or len(reads) != len(want) or "TEST:" in r.stdout:
            print(f"  {name}: exit {r.returncode}, {len(reads)} reads of {len(want)}", r.stdout[-300:], r.stderr[-200:])
            stale += 1
            continue
        runs += 1
        at = {}
        for (k, pos, text), word in zip(reads, want):
            shown = [x for x in text.split("|") if x]
            if len(shown) < 5:
                stale += 1
                print(f"  {name}: list {k} shows {len(shown)} rows")
            for x in shown:
                rows += 1
                if x.split()[1] != word:
                    stale += 1
                    print(f"  {name}: list {k} shows '{x}', should say {word}")
                    break
            lid = shown[0].split()[0] if shown else k
            if lid in at and at[lid] != pos and "third" not in name:
                moved += 1
                print(f"  {name}: list {lid} moved from {at[lid]} to {pos}")
            at[lid] = pos
    print("FACT rows", rows)
    print("FACT stale", stale)
    print("FACT moved", moved)
    print("FACT runs", runs)
    ok = stale == 0 and moved == 0 and runs == len(RUNS)
    print("gtk_lists: ok" if ok else "gtk_lists: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
