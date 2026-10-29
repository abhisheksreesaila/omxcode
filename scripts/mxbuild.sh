#!/usr/bin/env bash
# mojo build for a program that uses the omxcore engine package (vendor/omxcore.mojoc): the tests and tools.
#   scripts/mxbuild.sh tests/test_omx_files.mojo -o build/test_omx_files
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/mxlink.sh
exec pixi run mojo build --disable-warnings -I . -I vendor "$@" "${LINK[@]}"
