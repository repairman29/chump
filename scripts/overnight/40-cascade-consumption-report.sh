#!/usr/bin/env bash
# 40-cascade-consumption-report.sh — INFRA-260: nightly summary of which
# free-tier cascade slots actually carried traffic, with success rate and
# latency. Reads the chump_provider_quality table that provider_cascade.rs
# writes after every call (see src/provider_quality.rs). Emits a human-
# readable table on stderr plus a kind=cascade_report event into
# .chump-locks/ambient.jsonl so daytime agents can see what happened
# overnight without grepping logs.
#
# Also flags slots that have been silent for >= CASCADE_REPORT_IDLE_DAYS
# (default 3) — usually a bad key, a broken model name, or the bandit
# decided that slot was junk and stopped picking it. Either is worth
# investigating, so the alert points the operator at the right spot.
#
# Zero deps beyond sqlite3 + jq (both already required by the harness).

set -euo pipefail

DB="${CHUMP_MEMORY_DB:-sessions/chump_memory.db}"
AMBIENT="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
IDLE_DAYS="${CASCADE_REPORT_IDLE_DAYS:-3}"
NOW_UTC="$(date -u +%FT%TZ)"
TODAY="$(date -u +%F)"

if [ ! -r "$DB" ]; then
    echo "[cascade-report $NOW_UTC] sessions DB not found at $DB — skipping (cascade may not have run yet)" >&2
    exit 0
fi

# Pull the quality table; -1 latency means "never measured."
rows="$(sqlite3 -separator $'\t' "$DB" "
    SELECT
        slot_name,
        COALESCE(success_count, 0),
        COALESCE(sanity_fail_count, 0),
        COALESCE(printf('%.0f', latency_ms_p50), '-'),
        COALESCE(printf('%.0f', latency_ms_p95), '-'),
        COALESCE(last_updated, 'never')
    FROM chump_provider_quality
    ORDER BY last_updated DESC
" 2>/dev/null || echo "")"

if [ -z "$rows" ]; then
    echo "[cascade-report $NOW_UTC] no provider_quality rows yet — cascade hasn't recorded any calls" >&2
    exit 0
fi

# Header — fixed column widths so it's grep-friendly.
{
    printf '[cascade-report %s]\n' "$TODAY"
    printf '  %-12s %7s %5s %7s %7s  %s\n' \
        slot success fails 'p50ms' 'p95ms' last_updated
    echo "  ---------------------------------------------------------------"
} >&2

# Emit table + collect alerts in one pass.
alerts=()
slot_count=0
while IFS=$'\t' read -r slot succ fail p50 p95 last_upd; do
    slot_count=$((slot_count + 1))
    printf '  %-12s %7s %5s %7s %7s  %s\n' \
        "$slot" "$succ" "$fail" "$p50" "$p95" "$last_upd" >&2

    # Idle-slot detection: last_updated older than IDLE_DAYS
    if [ "$last_upd" != "never" ]; then
        last_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_upd" +%s 2>/dev/null \
                  || date -d "$last_upd" +%s 2>/dev/null \
                  || echo 0)
        now_epoch=$(date +%s)
        idle_days=$(( (now_epoch - last_epoch) / 86400 ))
        if [ "$idle_days" -ge "$IDLE_DAYS" ] && [ "$succ" = "0" ]; then
            alerts+=("$slot: 0 successes, idle ${idle_days}d (check key/model)")
        fi
    fi
done <<< "$rows"

# Build a JSON event for ambient.jsonl. jq does the escaping safely.
ts="$(date -u +%FT%TZ)"
report_json="$(jq -nc \
    --arg ts "$ts" \
    --arg event "cascade_report" \
    --arg today "$TODAY" \
    --argjson slot_count "$slot_count" \
    --arg rows "$rows" \
    '{ts: $ts, event: $event, day: $today, slot_count: $slot_count, raw: $rows}')"

mkdir -p "$(dirname "$AMBIENT")"
printf '%s\n' "$report_json" >> "$AMBIENT"

# Emit one ALERT line per idle slot so they show up in `tail -30 ambient.jsonl`
for msg in "${alerts[@]:-}"; do
    [ -z "$msg" ] && continue
    alert_json="$(jq -nc \
        --arg ts "$ts" \
        --arg event "ALERT" \
        --arg kind "slot_unused" \
        --arg msg "$msg" \
        '{ts: $ts, event: $event, kind: $kind, message: $msg}')"
    printf '%s\n' "$alert_json" >> "$AMBIENT"
done

echo "[cascade-report $NOW_UTC] done; slots=$slot_count alerts=${#alerts[@]}" >&2
