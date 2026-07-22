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

# Under launchd/app contexts LANG is unset → cut/sed slice BYTES, which can
# bisect a multibyte char (em-dashes in commit subjects) and emit invalid
# UTF-8 that strict decoders (Swift String) reject wholesale. Force UTF-8.
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

REPO="${CHUMP_REPO:-$HOME/Projects/Chump}"
MODE_FILE="${CHUMP_MODE_FILE:-$HOME/.chump/fleet-mode}"
STAMP="$HOME/.chump/chumpbar-last-fetch"
FETCH_TTL_S="${CHUMPBAR_FETCH_TTL_S:-300}"

cd "$REPO" 2>/dev/null || { echo '{"icon":"❓","error":"repo not found"}'; exit 0; }

now=$(date +%s)
last_fetch=$(stat -f %m "$STAMP" 2>/dev/null || echo 0)
if (( now - last_fetch > FETCH_TTL_S )); then
    touch "$STAMP"
    # >/dev/null: the backgrounded fetch must NOT inherit our stdout — the
    # ChumpBar app reads this pipe to EOF, and a hung fetch (credential
    # prompt under launchd env) held it open forever, starving the menu.
    (GIT_TERMINAL_PROMPT=0 git fetch origin main --quiet >/dev/null 2>&1 &)
fi

# RESILIENT-177: liveness = heartbeat freshness, not pgrep patterns — the
# AGENT_ID cmdline match broke across launcher styles and reported 0 while
# agent logs were actively moving (2026-07-19 counting bug).
workers=0
_hb_now=$(date +%s)
for _hb in /tmp/chump-fleet-worker-*.heartbeat; do
    [[ -f "$_hb" ]] || continue
    _hb_age=$(( _hb_now - $(stat -f %m "$_hb" 2>/dev/null || echo 0) ))
    (( _hb_age <= 180 )) && workers=$((workers + 1))
done
mode=$(cat "$MODE_FILE" 2>/dev/null || echo "off")

# ── EU fleet (chumpd-eu, 2026-07-22 migration) ──────────────────────────────
# The fleet's primary home is the Helsinki host. Refresh its status over ssh
# in the BACKGROUND on a TTL (never block the menu on the network), read the
# cached copy every call. The host-side emitter is scripts/ops/chump-eu-status.sh
# (deployed at /root/chump-eu-status.sh).
EU_HOST="${CHUMPBAR_EU_HOST:-root@204.168.229.237}"
EU_CACHE="$HOME/.chump/chumpbar-eu.json"
EU_TTL_S="${CHUMPBAR_EU_TTL_S:-120}"
eu_cache_age=$(( now - $(stat -f %m "$EU_CACHE" 2>/dev/null || echo 0) ))
if (( eu_cache_age > EU_TTL_S )); then
    ( ssh -o BatchMode=yes -o ConnectTimeout=4 "$EU_HOST" 'bash /root/chump-eu-status.sh' \
        > "$EU_CACHE.tmp" 2>/dev/null && [ -s "$EU_CACHE.tmp" ] && mv "$EU_CACHE.tmp" "$EU_CACHE" & )
fi
eu_ok=0; eu_broken=0; eu_mode="?"; eu_last10=""; eu_lines_json="[]"
if [[ -s "$EU_CACHE" ]]; then
    eu_ok=$(sed -E 's/.*"eu_ok":([0-9]+).*/\1/' "$EU_CACHE" 2>/dev/null || echo 0)
    eu_broken=$(sed -E 's/.*"eu_broken":([0-9]+).*/\1/' "$EU_CACHE" 2>/dev/null || echo 0)
    eu_mode=$(sed -E 's/.*"eu_mode":"([^"]*)".*/\1/' "$EU_CACHE" 2>/dev/null || echo "?")
    eu_last10=$(sed -E 's/.*"eu_last10":"([^"]*)".*/\1/' "$EU_CACHE" 2>/dev/null || echo "")
    eu_lines_json=$(sed -E 's/.*"eu_lines":(\[[^]]*\]).*/\1/' "$EU_CACHE" 2>/dev/null || echo "[]")
    [[ "$eu_lines_json" == \[* ]] || eu_lines_json="[]"
    _eu_stale_min=$(( eu_cache_age / 60 ))
    (( eu_cache_age > 600 )) && eu_mode="${eu_mode} (stale ${_eu_stale_min}m)"
fi

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
# Only show local worker lines when local heartbeats are actually live —
# otherwise yesterday's dead fleet dir renders ghost "warming up" rows.
(( workers == 0 )) && fleet_dir=""
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

# Icon reflects the WHOLE fleet: EU workers count as workers. The laptop
# dial being "off" no longer means the fleet is off — Helsinki grinds on.
total_workers=$(( workers + eu_ok ))
if (( total_workers == 0 )) && [[ "$mode" == "off" ]]; then
    icon="⚫"
elif (( total_workers == 0 )); then
    icon="🔴"
elif (( eu_broken > 0 )); then
    icon="🟠"
elif (( last_merge_min <= 120 )); then
    icon="🟢"
else
    icon="🟡"
fi

# Pure-bash JSON assembly (RESILIENT-177 follow-up): the python3 heredoc
# assembler hung when parented by the ChumpBar app (never reproduced under
# shells or launchd one-shots) — and a status surface must not depend on an
# interpreter spawn anyway. Titles are single-line; escape \ and ".
_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

_wd_json=""
for _l in "${worker_lines[@]:-}"; do
    [[ -n "$_l" ]] || continue
    _wd_json+="\"$(_esc "$_l")\","
done
# EU worker lines come pre-escaped/pre-formatted from the host emitter.
_eu_inner="${eu_lines_json#[}"; _eu_inner="${_eu_inner%]}"
if [[ -n "$_eu_inner" ]]; then
    _wd_json+="${_eu_inner},"
fi
if [[ -n "$eu_last10" ]]; then
    _wd_json+="\"🇫🇮 fleet: ${eu_ok}⚙ ${eu_broken}✗  mode=$(_esc "$eu_mode")  last10: $(_esc "$eu_last10")\","
fi
_wd_json="[${_wd_json%,}]"

_rs_json=""
while IFS= read -r _l; do
    [[ -n "$_l" ]] || continue
    _rs_json+="\"$(_esc "$_l")\","
done <<< "$recent_ships"
_rs_json="[${_rs_json%,}]"

printf '{"icon":"%s","mode":"%s","workers":%d,"ships_24h":%d,"last_merge_min":%d,"p0_open":"%s","open_gaps":"%s","workers_detail":%s,"recent_ships":%s}\n' \
    "$icon" "$(_esc "local:$mode eu:$eu_mode")" "${total_workers:-0}" "${ships_24h:-0}" "${last_merge_min:-0}" \
    "$(_esc "$p0_open")" "$(_esc "$open_gaps")" "$_wd_json" "$_rs_json"
