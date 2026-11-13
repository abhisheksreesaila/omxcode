#!/usr/bin/env python3
"""Fails when a module an omxcore app imports seeks a file handle (goal 68, docs/lessons.md 2026-11-12): the standard
library's FileHandle.seek and Process.log_tail (which seeks) declare lseek one way, omxcore's parquet another, and a
program may declare a C function only once, so the app stops building. Read at offsets with pread by address instead
(mojoui.bag's _File).

    pixi run python scripts/seek_lint.py [examples/omxplorer/app.mojo …]     (default: every example whose needs say omxcore)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMPORT = re.compile(r"^\s*from\s+mojoui\.([\w.]+)\s+import|^\s*from\s+mojoui\s+import\s+([\w, ]+)", re.M)


def closure(start):
    seen, todo = set(), [start]
    while todo:
        p = todo.pop()
        if p in seen or not p.exists():
            continue
        seen.add(p)
        for m in IMPORT.finditer(p.read_text()):
            names = [m.group(1)] if m.group(1) else [n.strip() for n in m.group(2).split(",")]
            for n in names:
                q = ROOT / "mojoui" / (n.replace(".", "/") + ".mojo")
                todo.append(q)
    return seen


def offenders(path):
    text = path.read_text()
    handles = set(re.findall(r"with open\([^)]*\)\s+as\s+(\w+)", text)) | set(re.findall(r"var (\w+) = open\(", text))
    bad = []
    for i, line in enumerate(text.splitlines(), 1):
        code = line.split("#")[0]
        for h in handles:
            if re.search(rf"\b{h}\.seek\(", code):
                bad.append(f"{path.relative_to(ROOT)}:{i}: {h}.seek(")
        if ".log_tail(" in code:
            bad.append(f"{path.relative_to(ROOT)}:{i}: log_tail( (seeks)")
    return bad


def main():
    starts = [Path(a) for a in sys.argv[1:]] or [p.parent / "app.mojo" for p in (ROOT / "examples").glob("*/needs") if "omxcore" in p.read_text().split()]
    found = []
    for s in starts:
        for m in sorted(closure((ROOT / s).resolve() if not s.is_absolute() else s)):
            found += [f"{s}: {b}" for b in offenders(m)]
    for f in sorted(set(found)):
        print(f)
    print(f"SEEK_LINT: {len(set(found))} file seeks in modules omxcore apps import")
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
