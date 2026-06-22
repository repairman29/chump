#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Exit 0 if healthy, non-zero if any alert fired.
#
# Pickable gaps: status=open, priority P0|P1, effort xs|s,
# no TODO acceptance_criteria, no blocking depends_on.
#
# Bash 3.2 compatible (macOS /bin/bash) — no declare -A / -n / mapfile.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# Ensure ambient directory exists before any >> writes.
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON array.
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Helper: returns true if AC string is a TODO placeholder.
is_todo_ac() {
    local ac="$1"
    echo "$ac" | grep -qiE '^[[:space:]]*(TODO|To Do|fixme)[[:space:]]*$'
}

# Helper: derive pillar from gap title prefix.
get_pillar() {
    local title="$1"
    case "$(echo "$title" | tr '[:lower:]' '[:upper:]')" in
        EFFECTIVE:*) echo "EFFECTIVE" ;;
        CREDIBLE:*)  echo "CREDIBLE"  ;;
        RESILIENT:*) echo "RESILIENT" ;;
        ZERO-WASTE:*)echo "ZERO-WASTE";;
        *)           echo "OTHER"     ;;
    esac
}

# Bash-3.2 compatible counters — one variable per pillar.
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

# Parse gaps and count pickable ones per pillar.
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(echo "$gap" | jq -r '.priority // ""' 2>/dev/null || true)
    effort=$(echo   "$gap" | jq -r '.effort   // ""' 2>/dev/null || true)
    ac=$(echo       "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || true)
    depends_on=$(echo "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || true)

    # Pickable: P0 or P1, effort xs or s.
    case "$priority" in P0|P1) ;; *) continue ;; esac
    case "$effort"   in xs|s)  ;; *) continue ;; esac

    # Skip TODO ACs.
    is_todo_ac "$ac" && continue

    # Skip gaps with blocking depends_on (non-empty array / non-null).
    if [[ "$depends_on" != "[]" && -n "$depends_on" && "$depends_on" != "null" ]]; then
        continue
    fi

    title=$(echo "$gap" | jq -r '.title // ""' 2>/dev/null || true)
    pillar=$(get_pillar "$title")

    case "$pillar" in
        EFFECTIVE)  count_EFFECTIVE=$((count_EFFECTIVE  + 1)) ;;
        CREDIBLE)   count_CREDIBLE=$((count_CREDIBLE    + 1)) ;;
        RESILIENT)  count_RESILIENT=$((count_RESILIENT  + 1)) ;;
        ZERO-WASTE) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
    esac
done < <(echo "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

check_pillar() {
    local pillar="$1" count="$2"

    # Under-fed: count < 2.
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Overweight: > 50% of total pickable pool.
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
check_pillar "ZERO-WASTE" "$count_ZERO_WASTE"

exit "$alert_fired"
