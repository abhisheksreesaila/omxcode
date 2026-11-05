#!/usr/bin/env bash
# mojo build for a program using mojoui, Flare and the engine (vendor/): scripts/mxbuild.sh's flags, with Flare's shims
# built first (scripts/flare_ffi.sh).
#   scripts/mojo_flare.sh build tests/test_serve.mojo -o build/test_serve
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/flare_ffi.sh >/dev/null
source scripts/mxlink.sh
cmd=$1; shift
exec pixi run mojo "$cmd" --disable-warnings -D MOJOUI_FLARE -I . -I vendor "$@" "${LINK[@]}"
