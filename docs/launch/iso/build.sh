#!/usr/bin/env bash
# Rebuild the cover's isometric diagrams from their JSON specs with the isoarch skill's build.py, dark by default
# (the cover is dark; the viewer's Theme button still switches), the template's panel blur removed (omxqua: no glass). Usage: docs/launch/iso/build.sh
set -euo pipefail
cd "$(dirname "$0")"
B="${ISOARCH:-$HOME/.claude/skills/isoarch}/scripts/build.py"
for spec in *.json; do
  html="${spec%.json}.html"
  python3 "$B" "$spec" "$html"
  sed -i '0,/<html lang="en">/s//<html lang="en" data-theme="dark">/' "$html"
  sed -i 's/-webkit-backdrop-filter:blur([0-9]*px);\?//g; s/backdrop-filter:blur([0-9]*px);\?//g' "$html"   # omxqua: opaque surfaces, no blur
done
