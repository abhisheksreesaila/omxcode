#!/usr/bin/env bash
# Blocks broad process kills (pkill -f, killall): they match by command text, so they hit other worktrees' checks and
# the agent's own shell (docs/lessons.md; it happened twice in goal 34). Stop only PIDs you started, or scripts/stop-check.
# Matches only where a command starts (line start, or after ; & | ( or sudo), not the words inside text or heredocs.
cmd=$(jq -r '.tool_input.command // ""')
if printf '%s\n' "$cmd" | grep -Eq '(^|[;&|(][[:space:]]*)(sudo[[:space:]]+)?(pkill[[:space:]]+(-[a-zA-Z]*f|--full)|killall)([[:space:]]|$)'; then
  echo "Blocked: pkill -f / killall match by command text and kill other checkouts' work and your own shell (docs/lessons.md). Kill only PIDs you started (kill <pid>), or use scripts/stop-check in your checkout." >&2
  exit 2
fi
exit 0
