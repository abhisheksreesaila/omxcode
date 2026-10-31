"""Every GTK test step verb is handled once (probe fixes, 2026-10-31): two `elif verb == "hold"` branches in run_step
meant the second (goal 41's Board hold) never ran, and goal 41 M8 failed after a merge. Fails on any verb compared twice.
Run: pixi run python tests/test_step_verbs.py     Prints `step verbs: ok`.
"""
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    src = (ROOT / "mojoui/hosts/gtk.mojo").read_text()
    body = src[src.index("def run_step["):]
    body = body[:body.index("\ndef ", 10)]  # (run_step only)
    names = Counter()
    # the top-level chain (4 spaces in): a verb named there twice shadows its second branch; nested `if verb ==` lines
    # inside a shared branch (drag, tapat...) only pick among that branch's verbs
    for line in re.findall(r'^    (?:el)?if (verb == .*?):', body, re.M):
        for v in re.findall(r'verb == "([a-z0-9_]+)"', line):
            names[v] += 1
    twice = sorted(v for v, n in names.items() if n > 1)
    if twice or not names:
        sys.exit(f"step verbs: FAIL: handled more than once in run_step: {twice}")
    print(f"step verbs: ok ({len(names)} verbs, each handled once)")


if __name__ == "__main__":
    main()
