"""Every X post in docs/launch/kit/x/*.md fits in 280 characters.

A post is the text between `---` lines that starts with a bold header line (`**1/** · …`, `**Mon Nov 2 · …**`).
The header and any italic source note are left out. Links count as 23 characters, as X counts them.

    pixi run python docs/launch/kit/x/check_lengths.py
"""
import re, sys
from pathlib import Path

URL = re.compile(r"(https?://\S+|\b[\w-]+(?:\.[\w-]+)*\.(?:com|tech|io|org|ai)(?:/\S*)?)")
over = 0
for f in sorted(Path(__file__).parent.glob("*.md")):
    for block in f.read_text().split("\n---\n"):
        lines = block.strip().splitlines()
        if not lines or not lines[0].startswith("**"):
            continue
        body = "\n".join(l for l in lines[1:] if not l.startswith("*")).strip()
        n = len(URL.sub("x" * 23, body))
        flag = "OVER" if n > 280 else "ok"
        over += n > 280
        print(f"{flag:>4} {n:>3}  {f.name}  {lines[0][:50]}")
sys.exit(1 if over else 0)
