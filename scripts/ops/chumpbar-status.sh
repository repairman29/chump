#!/usr/bin/env bash
# chumpbar-status.sh — fast ground-truth fleet status for the ChumpBar menu-bar app.
#
# Emits one line of JSON. Honest signals only (CREDIBLE-090 discipline):
#   ships_24h / last_merge_min  — from origin/main git history (the only proof of life)
#   workers                     — running worker.sh processes
#   p0_open                     — open P0 count from canonical state.db
#   mode                        — ~/.chump/fleet-mode (chump-mode dial)
#   icon                        — 🟢 shipping · 🟡 workers up, nothing merged recently
#                                 🔴 mode wants workers but none running · ⚫ off
#
# Network: at most one background `git fetch` per FETCH_TTL_S (default 300s);
# every other call is pure-local (<100ms). Safe to poll every 60s.

set -uo pipefail

REPO="${CHUMP_REPO:-$HOME/Projects/Chump}"
MODE_FILE="${CHUMP_MODE_FILE:-$HOME/.chump/fleet-mode}"
STAMP="$HOME/.chump/chumpbar-last-fetch"
FETCH_TTL_S="${CHUMPBAR_FETCH_TTL_S:-300}"

cd "$REPO" 2>/dev/null || { echo '{"icon":"❓","error":"repo not found"}'; exit 0; }

now=$(date +%s)
last_fetch=$(stat -f %m "$STAMP" 2>/dev/null || echo 0)
if (( now - last_fetch > FETCH_TTL_S )); then
    touch "$STAMP"
    (git fetch origin main --quiet 2>/dev/null &)
fi

# one launcher wrapper per worker carries AGENT_ID=N; bash fork copies don't
workers=$(pgrep -f 'AGENT_ID=[0-9]+ .*dispatch/worker\.sh' 2>/dev/null | wc -l | tr -d ' ')
mode=$(cat "$MODE_FILE" 2>/dev/null || echo "off")
last_merge_epoch=$(git log origin/main -1 --format=%ct 2>/dev/null || echo 0)
last_merge_min=$(( (now - last_merge_epoch) / 60 ))
ships_24h=$(git log origin/main --since='24 hours ago' --oneline 2>/dev/null | wc -l | tr -d ' ')
p0_open=$(sqlite3 .chump/state.db \
    "SELECT COUNT(*) FROM gaps WHERE status='open' AND priority='P0'" 2>/dev/null || echo "?")
open_gaps=$(sqlite3 .chump/state.db \
    "SELECT COUNT(*) FROM gaps WHERE status='open'" 2>/dev/null || echo "?")

if [[ "$mode" == "off" ]]; then
    icon="⚫"
elif (( workers == 0 )); then
    icon="🔴"
elif (( last_merge_min <= 120 )); then
    icon="🟢"
else
    icon="🟡"
fi

printf '{"icon":"%s","mode":"%s","workers":%s,"ships_24h":%s,"last_merge_min":%s,"p0_open":"%s","open_gaps":"%s"}\n' \
    "$icon" "$mode" "$workers" "$ships_24h" "$last_merge_min" "$p0_open" "$open_gaps"
