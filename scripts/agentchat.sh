#!/usr/bin/env bash
# The chat app on an AG-UI agent (goal 35). Starts the agent backend, then the app; stops the agent when the app closes.
#   scripts/agentchat.sh               the scripted agent (try: "Hello", "Show me sales as a chart", "Make me a signup form")
#   scripts/agentchat.sh --live        a live model: the OMX Console by default, or Claude (docs/agui.md)
#   scripts/agentchat.sh --web         the web build instead of GTK (http://127.0.0.1:5001)
set -euo pipefail
cd "$(dirname "$0")/.."
host=linux
mode=(--scenario chat)
for a in "$@"; do
  case "$a" in
    --live) mode=(--live) ;;
    --web) host=web ;;
  esac
done
port=${AGUI_PORT:-8765}
[ -e "build/agentchat/$host" ] || scripts/build.sh agentchat "$host"
pixi run python scripts/agui_agent.py --serve --port "$port" "${mode[@]}" &
agent=$!
trap 'kill "$agent" 2>/dev/null || true' EXIT
export AGUI_URL="http://127.0.0.1:$port/"
if [ "$host" = web ]; then
  pixi run python mojoui/hosts/web.py build/agentchat/web
else
  pixi run build/agentchat/linux/agentchat
fi
