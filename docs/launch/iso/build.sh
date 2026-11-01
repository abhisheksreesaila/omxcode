#!/usr/bin/env bash
# Rebuild the cover's isometric diagrams from their JSON specs with the isoarch skill's build.py (never hand-drawn),
# then chrome.py (shared with omxlabs.tech's iso/) gives them one fixed look inside the dark cover: only the drawing,
# its hover/click/select and the flow bar with Play; dark, ink, omxqua night tokens and the cover's accent; no blur.
# Usage: docs/launch/iso/build.sh            (ISOARCH=<skill dir> to point at another copy of the skill)
set -euo pipefail
cd "$(dirname "$0")"
B="${ISOARCH:-$HOME/.claude/skills/isoarch}/scripts/build.py"
for spec in *.json; do
  html="${spec%.json}.html"
  python3 "$B" "$spec" "$html"
  python3 chrome.py "$html" --accent "#ededef" --fonts ../../omxqua/src/fonts.css
done
