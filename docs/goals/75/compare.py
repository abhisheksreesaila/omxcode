#!/usr/bin/env python3
"""build/g75/compare.png (goal 75 M4's side-by-side, rebuilt 11-22 for goal 79 M7): our Buzan map (build/g75/map-ours.png,
written by tests/test_mindmap.mojo) beside Personal Note's own mind map (its screen shot headless from the web app:
build/g79/ref/mindmap.png, docs/goals/79/ref.mjs). The original was put together by hand in goal 75's session (not kept)."""
import sys
from PIL import Image
ours = Image.open(sys.argv[1] if len(sys.argv) > 1 else "build/g75/map-ours.png").convert("RGB")
pn = Image.open(sys.argv[2] if len(sys.argv) > 2 else "build/g79/ref/mindmap.png").convert("RGB")
h = max(ours.height, pn.height)
out = Image.new("RGB", (ours.width + pn.width + 16, h), (255, 255, 255))
out.paste(ours, (0, 0))
out.paste(pn, (ours.width + 16, 0))
out.save(sys.argv[3] if len(sys.argv) > 3 else "build/g75/compare.png")
print("compare.png:", out.size)
