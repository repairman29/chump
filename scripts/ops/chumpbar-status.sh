#!/usr/bin/env bash
# chumpbar-status.sh — fast ground-truth fleet status for the ChumpBar menu-bar app.
#
# Emits one line of JSON. Honest signals only (CREDIBLE-090 discipline):
#   ships_24h / last_merge_min  — from origin/main git history (the only proof of life)
#   workers / workers_detail    — AGENT_ID launcher processes + last picked gap per agent log
#   recent_ships                — last 3 merged subjects on origin/main
#   p0_open / open_gaps         — canonical state.db
#   mode                        — ~/.chump/fleet-mode (chump-mode dial)
#   icon                        — 🟢 shipping · 🟡 workers up, no merge in 2h
#                                 🔴 mode wants workers but none running · ⚫ off
#
# Network: at most one background `git fetch` per FETCH_TTL_S (default 300s);
# every other call is pure-local. Safe to poll every 60s.

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

# Per-worker: last picked gap from the newest fleet-launch log dir + its title.
# Log lines look like: [worker:1 15:10:19] picked gap INFRA-1730
worker_lines=()
fleet_dir=$(ls -td /tmp/chump-fleet-*/ 2>/dev/null | head -1)
if [[ -n "$fleet_dir" ]]; then
    for log in "$fleet_dir"/agent-[0-9].log; do
        [[ -f "$log" ]] || continue
        agent=$(basename "$log" .log | sed 's/agent-//')
        gap=$(grep -o 'picked gap [A-Z-]*-[0-9]*' "$log" 2>/dev/null | tail -1 | awk '{print $3}')
        if [[ -n "$gap" ]]; then
            title=$(sqlite3 .chump/state.db \
                "SELECT substr(title,1,48) FROM gaps WHERE id='$gap'" 2>/dev/null)
            # idle if the log hasn't moved in 10 min
            log_age=$(( now - $(stat -f %m "$log" 2>/dev/null || echo 0) ))
            marker="⚙"
            (( log_age > 600 )) && marker="💤"
            worker_lines+=("W${agent} ${marker} ${gap}: ${title}")
        else
            worker_lines+=("W${agent} ⚙ warming up")
        fi
    done
fi

recent_ships=$(git log origin/main -3 --format='%s' 2>/dev/null | cut -c1-60)

if [[ "$mode" == "off" ]]; then
    icon="⚫"
elif (( workers == 0 )); then
    icon="🔴"
elif (( last_merge_min <= 120 )); then
    icon="🟢"
else
    icon="🟡"
fi

# python3 assembles valid JSON regardless of quotes/emoji in titles
ICON="$icon" MODE="$mode" WORKERS="$workers" SHIPS="$ships_24h" \
LAST_MIN="$last_merge_min" P0="$p0_open" OPEN="$open_gaps" \
WORKER_LINES="$(printf '%s\n' "${worker_lines[@]:-}")" \
RECENT_SHIPS="$recent_ships" \
python3 - <<'PY'
import json, os
def lines(k): return [l for l in os.environ.get(k, "").splitlines() if l.strip()]
print(json.dumps({
    "icon": os.environ["ICON"], "mode": os.environ["MODE"],
    "workers": int(os.environ["WORKERS"] or 0),
    "ships_24h": int(os.environ["SHIPS"] or 0),
    "last_merge_min": int(os.environ["LAST_MIN"] or 0),
    "p0_open": os.environ["P0"], "open_gaps": os.environ["OPEN"],
    "workers_detail": lines("WORKER_LINES"),
    "recent_ships": lines("RECENT_SHIPS"),
}, ensure_ascii=False))
PY
