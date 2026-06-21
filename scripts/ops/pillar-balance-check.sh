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
#
# Bash 3.2 compatible (no declare -A / mapfile / readarray).

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

# Ensure directory exists (CHECKLIST item 2)
mkdir -p "$(dirname "$AMBIENT")"

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

# Count pickable gaps per pillar using simple variables (Bash 3.2 compatible)
effective_count=0
credible_count=0
resilient_count=0
zerowaste_count=0
other_count=0

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
    case "$pillar" in
        EFFECTIVE)   ((effective_count++)) || true ;;
        CREDIBLE)    ((credible_count++)) || true ;;
        RESILIENT)   ((resilient_count++)) || true ;;
        ZERO-WASTE)  ((zerowaste_count++)) || true ;;
        OTHER)       ((other_count++)) || true ;;
    esac
done < <(echo "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

# Calculate totals and thresholds
total_pickable=$((effective_count + credible_count + resilient_count + zerowaste_count))

# Emit alerts
alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Helper to emit alert for under-fed pillar
check_pillar() {
    local pillar="$1" count="$2"

    # Alert 1: Pillar under-fed (< 2)
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Alert 2: Pillar overweight (> 50% of total)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$pillar" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
}

check_pillar "EFFECTIVE" "$effective_count"
check_pillar "CREDIBLE" "$credible_count"
check_pillar "RESILIENT" "$resilient_count"
check_pillar "ZERO-WASTE" "$zerowaste_count"

# Exit non-zero if alerts fired
if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
