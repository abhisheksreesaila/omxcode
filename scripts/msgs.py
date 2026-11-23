"""An app's messages mustn't collide: each `comptime NAME = N` an app's update() compares with `m == NAME` must lie outside
every range it claims with `m >= BASE and m < BASE + K` (or `<= BASE + K`). A collision makes one control do another's
work (goal 30: the island's messages sat inside STYLE_ALIGN's range, so pressing the island aligned the selected cells).

  pixi run python scripts/msgs.py examples/omxplorer/app.mojo   # exit 1 and the collisions, if any
"""

import re
import sys
from pathlib import Path


def collisions(path):
    src = Path(path).read_text()
    consts = {}
    root = Path(__file__).resolve().parent.parent
    for lib in sorted((root / "mojoui").glob("*.mojo")):  # (constants the app imports: ALIGN_RIGHT, TILE_LAST…); the app's own win
        for name, value in re.findall(r"^comptime ([A-Z][A-Z0-9_]*) = ([0-9_]+)\b", lib.read_text(), re.M):
            consts.setdefault(name, int(value.replace("_", "")))
    for name, value in re.findall(r"^comptime ([A-Z][A-Z0-9_]*) = ([0-9_]+)\b", src, re.M):
        consts[name] = int(value.replace("_", ""))

    def value(expr):
        expr = expr.strip()
        for name in sorted(consts, key=len, reverse=True):
            expr = re.sub(rf"\b{name}\b", str(consts[name]), expr)
        if not re.fullmatch(r"[0-9+*() -]+", expr):
            return None
        return eval(expr)

    ranges = []
    for base, op, top in re.findall(r"\bm >= ([A-Z][A-Z0-9_]*) and m (<=?) ([^:\n]+):", src):
        top = re.split(r" or | and ", top)[0]
        while top.count(")") > top.count("("):  # (the condition's own closing parenthesis)
            top = top[:top.rfind(")")]
        lo, hi = value(base), value(top)
        if lo is None or hi is None:
            continue
        ranges.append((base, lo, hi + (1 if op == "<=" else 0)))
    # each `m == NAME` and `m == NAME + k` (a two-message pair like TAB, TAB + 1: 2026-11-22, goal 78's CANVAS_MODE = 94 was
    # TAB + 1, so a click on the Report tab toggled the canvas setting instead)
    singles = {}
    for name, k in re.findall(r"\bm == ([A-Z][A-Z0-9_]*)(?: \+ ([0-9]+))?\b", src):
        if name in consts:
            singles[name if not k else f"{name} + {k}"] = (name, consts[name] + int(k or 0))
    found = []
    for label, (name, v) in sorted(singles.items()):
        for base, lo, hi in ranges:
            if lo <= v < hi and name != base:
                found.append(f"{label} = {v} lies in {base}'s range {lo}–{hi - 1}")
    by_value = {}  # (two messages update() tells apart by `m ==` with one number: the first branch takes both, goal 78 review 1)
    for label, (name, v) in sorted(singles.items()):
        by_value.setdefault(v, []).append(label)
    for v, names in sorted(by_value.items()):
        if len(names) > 1:
            found.append(f"{' and '.join(names)} are all {v}")
    return found


if __name__ == "__main__":
    bad = []
    for p in sys.argv[1:] or ["examples/omxplorer/app.mojo"]:
        bad += [f"{p}: {c}" for c in collisions(p)]
    print("\n".join(bad) or "no message collisions")
    sys.exit(1 if bad else 0)
