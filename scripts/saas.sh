#!/usr/bin/env bash
# The saas demo's server (goal 57): examples/saas/server.mojo, nothing but mojoui on Flare.
#   scripts/saas.sh build          → build/saas/server
#   scripts/saas.sh run            build, then run it with ~/.config/omxcode/saas.env's keys (never printed)
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-build}" in
  build)
    mkdir -p build/saas; rm -f build/saas/server  # (a failed build must not leave the old binary passing for it)
    scripts/mojo_flare.sh build examples/saas/server.mojo -o build/saas/server 2>&1 | grep -v telemetry || true
    test -x build/saas/server ;;
  run)
    "$0" build
    keys=~/.config/omxcode/saas.env
    if [ -f "$keys" ]; then  # (sourced as shell: only if it's ours and nobody else can read or write it)
      mode=$(stat -c %a "$keys" 2>/dev/null || stat -f %Lp "$keys")
      [ -O "$keys" ] && [ "$mode" = 600 ] || { echo "refusing $keys: make it yours with mode 600 (chmod 600)" >&2; exit 1; }
      set -a; . "$keys"; set +a
    fi
    umask 077
    : "${SAAS_SECRET:=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
    export SAAS_SECRET SAAS_DATA="${SAAS_DATA:-$PWD/build/saas/data}" SAAS_PORT="${SAAS_PORT:-8000}"
    mkdir -p "$SAAS_DATA"; chmod 700 "$SAAS_DATA"
    export SAAS_BASE="${SAAS_BASE:-http://127.0.0.1:$SAAS_PORT}"
    exec build/saas/server ;;
  *) echo "usage: scripts/saas.sh build|run" >&2; exit 2 ;;
esac
