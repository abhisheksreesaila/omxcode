#!/usr/bin/env bash
# scripts/tablet.sh <app> [https-port]: an app on this machine, with another device (a tablet, a phone) as its screen, microphone
# and speaker (goal 72 M5, docs/web-audio.md).
#
# Starts the app on the web host (loopback only), puts it on your tailnet with `tailscale serve` (https://<machine>.<tailnet>.ts.net:
# <port> -> http://127.0.0.1:<port>: a real certificate, which a browser needs before it lets a page use the microphone), and
# prints the address to open on the device, with the pairing key on its first visit (?k=). The key is moved into a cookie, so
# bookmark the address without it. Without the key the host answers 403, on the tailnet or anywhere else.
#
# The https port is the first free one from 8444 up (443, 8443 and 10000 are other services' here); $MOJOUI_TABLET_PORT picks
# one. Existing `tailscale serve` entries are never touched: only the one this script adds, and it takes that one away again
# when you press Ctrl-C. An app that needs one of the pixi environments (examples/<app>/needs: speech, voice…) runs in it;
# $TABLET_ENV overrides.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: scripts/tablet.sh <app> [https-port]}"
MODULE="build/$APP/web"
[ -f "$MODULE/mojoui_app.so" ] || scripts/build.sh "$APP" web

command -v tailscale >/dev/null || { echo "tablet: tailscale isn't installed" >&2; exit 1; }
NAME="$(tailscale status --json | pixi run python -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip(".").lower())')"
[ -n "$NAME" ] || { echo "tablet: tailscale isn't connected (tailscale up)" >&2; exit 1; }

# the https port: the first one from 8444 that has no `tailscale serve` entry
HTTPS="${2:-${MOJOUI_TABLET_PORT:-}}"
if [ -z "$HTTPS" ]; then
  HTTPS="$(tailscale serve status --json | pixi run python -c '
import json, sys
used = {k.rsplit(":", 1)[1] for k in (json.load(sys.stdin).get("Web") or {})}
print(next(p for p in range(8444, 8500) if str(p) not in used))')"
fi

ENVNAME="${TABLET_ENV:-$(head -1 "examples/$APP/needs" 2>/dev/null || true)}"
RUN=(pixi run); [ -n "$ENVNAME" ] && RUN=(pixi run -e "$ENVNAME")
PORT="$(pixi run python -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
KEY="$(pixi run python mojoui/hosts/web.py --pair-key)"

SERVED=0
cleanup() {
  [ "$SERVED" = 1 ] && tailscale serve --https="$HTTPS" off >/dev/null 2>&1 || true
  kill "${SERVER:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

MOJOUI_EXTRA_HOSTS="$NAME" "${RUN[@]}" python mojoui/hosts/web.py "$MODULE" "$PORT" &
SERVER=$!
for _ in $(seq 1 120); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
  kill -0 "$SERVER" 2>/dev/null || { echo "tablet: the web host stopped" >&2; exit 1; }
  sleep 0.5
done

tailscale serve --bg --https="$HTTPS" "http://127.0.0.1:$PORT" >/dev/null
SERVED=1
echo
echo "  $APP is on your tailnet. Open this on the device (the key is only needed the first time):"
echo
echo "    https://$NAME:$HTTPS/?k=$KEY"
echo
echo "  Tap the page once to turn sound on. Ctrl-C stops the app and takes the address away."
wait "$SERVER"
