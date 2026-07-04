#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Pickable gaps: status=open, priority P0|P1, effort xs|s,
#   non-empty AC (not TODO placeholder), no blocking depends_on.
#
# Exit 0 if healthy, non-zero if any alert fired.
#
# Bash 3.2 compatible (macOS /bin/bash): no declare -A/-n, no mapfile/readarray.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON array
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Bash 3.2 compatible per-pillar counters (no declare -A)
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

# Parse each gap from the JSON array; jq -c '.[]' emits one object per line
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(printf '%s' "$gap" | jq -r '.priority // ""' 2>/dev/null || true)
    effort=$(printf '%s' "$gap" | jq -r '.effort // ""' 2>/dev/null || true)
    ac=$(printf '%s' "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || true)
    depends_on=$(printf '%s' "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || true)
    title=$(printf '%s' "$gap" | jq -r '.title // ""' 2>/dev/null || true)

    # Must be P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Must be xs or s effort
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Skip TODO/empty AC
    ac_stripped=$(printf '%s' "$ac" | tr -d '[:space:]')
    case "$ac_stripped" in
        ""|\
        TODO|todo|ToDo|\
        FIXME|fixme) continue ;;
    esac

    # Skip if blocking deps present (non-empty array)
    if [[ "$depends_on" != "[]" && -n "$depends_on" ]]; then continue; fi

    # Classify by pillar prefix (case-insensitive)
    title_lower=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
    case "$title_lower" in
        effective:*) count_EFFECTIVE=$((count_EFFECTIVE + 1)) ;;
        credible:*)  count_CREDIBLE=$((count_CREDIBLE + 1)) ;;
        resilient:*) count_RESILIENT=$((count_RESILIENT + 1)) ;;
        zero-waste:*) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
    esac
done < <(printf '%s' "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

# Total pickable across the 4 pillars
total=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
alert_fired=0

emit_alert() {
    local pillar="$1" count="$2"
    printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
        "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
    alert_fired=1
}

emit_overweight() {
    local pillar="$1" count="$2" pct="$3"
    printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
        "$emit_ts" "$pillar" "$count" "$pct" >> "$AMBIENT"
    alert_fired=1
}

check_pillar() {
    local pillar="$1" count="$2"

    if [[ "$count" -lt 2 ]]; then
        emit_alert "$pillar" "$count"
    fi

    if [[ "$total" -gt 0 ]]; then
        local pct=$((count * 100 / total))
        if [[ "$pct" -gt 50 ]]; then
            emit_overweight "$pillar" "$count" "$pct"
        fi
    fi
}

check_pillar "EFFECTIVE"  "$count_EFFECTIVE"
check_pillar "CREDIBLE"   "$count_CREDIBLE"
check_pillar "RESILIENT"  "$count_RESILIENT"
check_pillar "ZERO-WASTE" "$count_ZERO_WASTE"

if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
