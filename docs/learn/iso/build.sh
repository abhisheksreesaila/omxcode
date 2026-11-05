#!/usr/bin/env bash
# Rebuild the deck's isometric diagrams from their JSON specs with the isoarch skill's build.py (never hand-drawn),
# then the launch page's chrome.py gives them the one dark look (drawing, hover/click, flow bar with Play) in the deck's coral.
# Usage: docs/learn/iso/build.sh            (ISOARCH=<skill dir> to point at another copy of the skill)
set -euo pipefail
cd "$(dirname "$0")"
B="${ISOARCH:-$HOME/.claude/skills/isoarch}/scripts/build.py"
for spec in *.json; do
  html="${spec%.json}.html"
  python3 "$B" "$spec" "$html"
  python3 ../../launch/iso/chrome.py "$html" --accent "#ff5d6c" --fonts ../../omxqua/src/fonts.css
done
