#!/usr/bin/env bash
# chump-eu-status.sh — one-line JSON fleet status for ChumpBar, emitted ON the EU host.
# Called over ssh by scripts/ops/chumpbar-status.sh (laptop). Pure-local reads only.
set -uo pipefail
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=en_US.UTF-8

REPO="${CHUMP_REPO:-/root/Chump}"
now=$(date +%s)

_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# chumpd status: worker slots + mode
workers_ok=0; workers_broken=0; mode="?"
if [[ -f /tmp/chumpd-status.json ]]; then
    read -r workers_ok workers_broken mode < <(python3 - <<'PY'
import json
try:
    d = json.load(open("/tmp/chumpd-status.json"))
    ok = sum(1 for w in d.get("workers", []) if not w.get("broken"))
    broken = sum(1 for w in d.get("workers", []) if w.get("broken"))
    print(ok, broken, d.get("mode", "?"))
except Exception:
    print(0, 0, "?")
PY
)
fi

# Per-agent: last picked gap + activity marker from the newest fleet dir.
lines=""
fleet_dir=$(ls -td /tmp/chumpd-fleet-*/ 2>/dev/null | head -1)
if [[ -n "$fleet_dir" ]]; then
    for log in "$fleet_dir"agent-[0-9].log; do
        [[ -f "$log" ]] || continue
        agent=$(basename "$log" .log | sed 's/agent-//')
        gap=$(grep -ao 'picked gap [A-Z-]*-[0-9]*' "$log" 2>/dev/null | tail -1 | awk '{print $3}')
        log_age=$(( now - $(stat -c %Y "$log" 2>/dev/null || echo 0) ))
        marker="⚙"; (( log_age > 600 )) && marker="💤"
        if [[ -n "$gap" ]]; then
            title=$(sqlite3 "$REPO/.chump/state.db" \
                "SELECT substr(title,1,44) FROM gaps WHERE id='$gap'" 2>/dev/null || true)
            lines+="\"🇫🇮 W${agent} ${marker} ${gap}: $(_esc "$title")\","
        else
            lines+="\"🇫🇮 W${agent} ${marker} warming up\","
        fi
    done
fi
lines="[${lines%,}]"

# Cycle outcomes: last 10 cycle_end lines across agents → shipped/failed tally.
shipped=0; failed=0
if [[ -n "$fleet_dir" ]]; then
    while IFS= read -r l; do
        case "$l" in
            *kind=shipped*) shipped=$((shipped+1)) ;;
            *) failed=$((failed+1)) ;;
        esac
    done < <(grep -ah 'cycle_end' "$fleet_dir"agent-*.log 2>/dev/null | tail -10)
fi

printf '{"eu_ok":%d,"eu_broken":%d,"eu_mode":"%s","eu_lines":%s,"eu_last10":"%d✓/%d✗","ts":%d}\n' \
    "$workers_ok" "$workers_broken" "$(_esc "$mode")" "$lines" "$shipped" "$failed" "$now"
