#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Bash 3.2 compatible pillar balance health check (no declare -A).
# Counts open pickable gaps per pillar (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE)
# and emits alerts to ambient.jsonl when any pillar is under-fed (< 2) or
# overweight (> 50% of total pickable pool).
#
# Pickable = status open, priority P0|P1, effort xs|s,
#            non-TODO acceptance_criteria, no blocking depends_on.
#
# Exit 0 if healthy, non-zero if any alert fired.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

# Ensure the ambient log directory exists before any >> write
mkdir -p "$(dirname "$AMBIENT")"

# Fetch all open gaps as a JSON array
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Bash 3.2 compatible counters — no associative arrays
effective_count=0
credible_count=0
resilient_count=0
zero_waste_count=0

# Parse each gap line and apply pickability filters
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(echo "$gap" | jq -r '.priority // ""' 2>/dev/null) || continue
    effort=$(echo "$gap"   | jq -r '.effort // ""'   2>/dev/null) || continue
    ac=$(echo "$gap"       | jq -r '.acceptance_criteria // ""' 2>/dev/null) || continue
    depends_on=$(echo "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null) || continue
    title=$(echo "$gap"    | jq -r '.title // ""'    2>/dev/null) || continue

    # Priority must be P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Effort must be xs or s
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Skip TODO / placeholder ACs
    if echo "$ac" | grep -qiE '^\s*(TODO|to do|fixme)\s*$'; then continue; fi

    # Skip gaps with a non-empty depends_on list
    if [[ "$depends_on" != "[]" && -n "$depends_on" ]]; then continue; fi

    # Identify pillar from title prefix (case-insensitive)
    title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')
    if echo "$title_lower" | grep -q '^effective:'; then
        effective_count=$((effective_count + 1))
    elif echo "$title_lower" | grep -q '^credible:'; then
        credible_count=$((credible_count + 1))
    elif echo "$title_lower" | grep -q '^resilient:'; then
        resilient_count=$((resilient_count + 1))
    elif echo "$title_lower" | grep -q '^zero-waste:'; then
        zero_waste_count=$((zero_waste_count + 1))
    fi
done < <(echo "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((effective_count + credible_count + resilient_count + zero_waste_count))

alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for pillar_name in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    case "$pillar_name" in
        EFFECTIVE)  count=$effective_count ;;
        CREDIBLE)   count=$credible_count ;;
        RESILIENT)  count=$resilient_count ;;
        ZERO-WASTE) count=$zero_waste_count ;;
        *)          count=0 ;;
    esac

    # Under-fed alert
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar_name" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Overweight alert (> 50% of total)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$pillar_name" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
done

exit $alert_fired
