#!/usr/bin/env bash
# The saas demo's server (goal 57): examples/saas/server.mojo, nothing but mojoui on Flare.
#   scripts/saas.sh build          → build/saas/server
#   scripts/saas.sh run            build, then run it with ~/.config/omxcode/saas.env's keys (never printed)
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-build}" in
  build)
    mkdir -p build/saas
    scripts/mojo_flare.sh build examples/saas/server.mojo -o build/saas/server 2>&1 | grep -v telemetry || true
    test -x build/saas/server ;;
  run)
    "$0" build
    set -a; [ -f ~/.config/omxcode/saas.env ] && . ~/.config/omxcode/saas.env; set +a
    : "${SAAS_SECRET:=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
    export SAAS_SECRET SAAS_DATA="${SAAS_DATA:-$PWD/build/saas/data}" SAAS_PORT="${SAAS_PORT:-8000}"
    export SAAS_BASE="${SAAS_BASE:-http://127.0.0.1:$SAAS_PORT}"
    exec build/saas/server ;;
  *) echo "usage: scripts/saas.sh build|run" >&2; exit 2 ;;
esac
