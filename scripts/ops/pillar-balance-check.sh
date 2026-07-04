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
# Bash 3.2 compatible (macOS /bin/bash) — no declare -A / mapfile / readarray.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# Ensure the ambient directory exists before we try to write to it.
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Individual pillar counters — Bash 3.2 has no associative arrays.
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZEROWASTE=0   # ZERO-WASTE stored without the hyphen for var names

# Helper: detect TODO acceptance_criteria
is_todo_ac() {
    local ac="$1"
    echo "$ac" | grep -qiE '^[[:space:]]*(TODO|To Do|fixme)[[:space:]]*$'
}

# Parse JSON, filter pickable gaps, and count per pillar.
# We iterate over each gap object, check pickability, extract the pillar prefix.
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(echo "$gap" | jq -r '.priority // ""' 2>/dev/null || echo "")
    effort=$(echo "$gap" | jq -r '.effort // ""' 2>/dev/null || echo "")
    ac=$(echo "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || echo "")
    depends_on=$(echo "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || echo "[]")
    title=$(echo "$gap" | jq -r '.title // ""' 2>/dev/null || echo "")

    # Must be P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Must be xs or s effort
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Skip if TODO AC
    if is_todo_ac "$ac"; then continue; fi

    # Skip if has blocking depends_on (non-empty, non-null array)
    if [[ "$depends_on" != "[]" ]] && [[ "$depends_on" != "null" ]] && [[ -n "$depends_on" ]]; then continue; fi

    # Identify pillar from title prefix (case-insensitive)
    if echo "$title" | grep -qi '^EFFECTIVE:'; then
        count_EFFECTIVE=$((count_EFFECTIVE + 1))
    elif echo "$title" | grep -qi '^CREDIBLE:'; then
        count_CREDIBLE=$((count_CREDIBLE + 1))
    elif echo "$title" | grep -qi '^RESILIENT:'; then
        count_RESILIENT=$((count_RESILIENT + 1))
    elif echo "$title" | grep -qi '^ZERO-WASTE:'; then
        count_ZEROWASTE=$((count_ZEROWASTE + 1))
    fi
done < <(echo "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZEROWASTE))

alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Check each pillar in a loop using positional parameters to stay Bash 3.2 safe.
check_pillar() {
    local pillar="$1"
    local count="$2"

    # Under-fed alert (< 2)
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Overweight alert (> 50% of total)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$pillar" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
}

check_pillar "EFFECTIVE"  "$count_EFFECTIVE"
check_pillar "CREDIBLE"   "$count_CREDIBLE"
check_pillar "RESILIENT"  "$count_RESILIENT"
check_pillar "ZERO-WASTE" "$count_ZEROWASTE"

if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
