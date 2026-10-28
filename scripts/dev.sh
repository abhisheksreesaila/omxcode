#!/usr/bin/env bash
# The developer loop for an app's JavaScript (docs/js.md, goal 34b M1c):
#   scripts/dev.sh <app> [--port 5001]
# builds the app for the web as a debug build (source maps), serves it on http://127.0.0.1:<port>/ only, and watches
# examples/<app>/web/: saving a .ts, .js or .css file rebuilds the bundles and every open page loads the new code and
# mounts those widgets again with Mojo's props, the app's state untouched. A widget's uncaught error is printed here as
# "JS ERROR: widgets/<file>:<line>:<column>: <message>". Stop with Ctrl+C. Never used by release builds.
set -euo pipefail
cd "$(dirname "$0")/.."
exec pixi run python scripts/dev.py "$@"
