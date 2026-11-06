"""Fails when docs/decisions.md gives one decision number to two decisions (the merge of goals 50 and 52 into main
found D-4757..D-4765 used by both sides; goal 50's became D-4779..D-4787). Numbers that were doubled before this lint
existed are listed in KNOWN: their citations can't be told apart now, so they stay as they are.
  pixi run python scripts/decisions_lint.py"""
import collections
import re
import sys
from pathlib import Path

KNOWN = {"D-177", "D-739", "D-1700", "D-1701", "D-1702", "D-1703", "D-1704", "D-1705", "D-1706", "D-1707"}
text = (Path(__file__).resolve().parent.parent / "docs/decisions.md").read_text()
count = collections.Counter(re.findall(r"^- (D-\d+) ", text, re.M))
doubled = sorted((d for d, n in count.items() if n > 1 and d not in KNOWN), key=lambda d: int(d[2:]))
if doubled:
    sys.exit("decisions lint: used twice: " + ", ".join(doubled) + " (give the newer one the next free number)")
print(f"decisions lint: ok ({len(count)} numbers)")
