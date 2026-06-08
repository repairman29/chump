#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Exit 0 if healthy, non-zero if any alert fired.
#
# Pickable gaps are: status=open, priority P0|P1, effort xs|s,
# no TODO acceptance_criteria, no blocking depends_on.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

# Read all open gaps as JSON
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Helper to check if an AC is a TODO placeholder
is_todo_ac() {
    local ac="$1"
    [[ "$ac" =~ ^[[:space:]]*(TODO|[Tt]o [Dd]o|fixme|FIXME)[[:space:]]*$ ]]
}

# Helper to extract pillar from title (case-insensitive)
get_pillar() {
    local title="$1"
    if echo "$title" | grep -qi '^EFFECTIVE:'; then echo "EFFECTIVE"
    elif echo "$title" | grep -qi '^CREDIBLE:'; then echo "CREDIBLE"
    elif echo "$title" | grep -qi '^RESILIENT:'; then echo "RESILIENT"
    elif echo "$title" | grep -qi '^ZERO-WASTE:'; then echo "ZERO-WASTE"
    else echo "OTHER"; fi
}

# Count pickable gaps per pillar
declare -A pillar_count
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE OTHER; do
    pillar_count["$p"]=0
done

# Parse JSON and filter pickable gaps
while IFS= read -r gap; do
    if [[ -z "$gap" ]]; then continue; fi

    priority=$(echo "$gap" | jq -r '.priority // ""' 2>/dev/null || echo "")
    effort=$(echo "$gap" | jq -r '.effort // ""' 2>/dev/null || echo "")
    ac=$(echo "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || echo "")
    depends_on=$(echo "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || echo "[]")

    # Check if pickable: P0 or P1, effort xs or s, no TODO AC, no blocking deps
    if [[ ! "$priority" =~ ^P[01]$ ]]; then continue; fi
    if [[ ! "$effort" =~ ^(xs|s)$ ]]; then continue; fi
    if is_todo_ac "$ac"; then continue; fi

    # Check for blocking depends_on (non-empty array)
    if [[ "$depends_on" != "[]" ]] && [[ -n "$depends_on" ]]; then continue; fi

    # Get pillar and increment counter
    pillar=$(get_pillar "$(echo "$gap" | jq -r '.title // ""' 2>/dev/null || echo "")")
    ((pillar_count["$pillar"]++)) || true
done < <(echo "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

# Calculate totals and thresholds
total_pickable=0
for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    ((total_pickable += pillar_count["$p"])) || true
done

# Emit alerts
alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    count=${pillar_count["$p"]:-0}

    # Alert 1: Pillar under-fed (< 2)
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$p" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Alert 2: Pillar overweight (> 50% of total)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$p" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
done

# Exit non-zero if alerts fired
if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
