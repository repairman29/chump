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
# Bash 3.2 compatible — no declare -A / mapfile / readarray.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

# Ensure the ambient directory exists before appending.
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Count pickable gaps per pillar using separate scalar variables (Bash 3.2 safe).
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

# Parse each gap object and test pickability.
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(printf '%s' "$gap" | jq -r '.priority // ""' 2>/dev/null || true)
    effort=$(printf '%s' "$gap" | jq -r '.effort // ""' 2>/dev/null || true)
    ac=$(printf '%s' "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || true)
    depends_on=$(printf '%s' "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || true)
    title=$(printf '%s' "$gap" | jq -r '.title // ""' 2>/dev/null || true)

    # Priority must be P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Effort must be xs or s
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Reject TODO/placeholder ACs
    case "$ac" in
        TODO|todo|"TODO: "*|"To Do"|"FIXME"|"fixme"|"") continue ;;
    esac
    if printf '%s' "$ac" | grep -qiE '^\s*(TODO|to do|fixme)\s*$'; then
        continue
    fi

    # Reject if depends_on is non-empty (has blocking deps)
    if [[ "$depends_on" != "[]" && -n "$depends_on" ]]; then
        continue
    fi

    # Classify by pillar prefix (case-insensitive prefix match)
    pillar_key=""
    lower_title=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
    case "$lower_title" in
        effective:*) pillar_key="EFFECTIVE" ;;
        credible:*)  pillar_key="CREDIBLE"  ;;
        resilient:*) pillar_key="RESILIENT" ;;
        zero-waste:*) pillar_key="ZERO_WASTE" ;;
        *) continue ;;
    esac

    case "$pillar_key" in
        EFFECTIVE)  count_EFFECTIVE=$((count_EFFECTIVE + 1))   ;;
        CREDIBLE)   count_CREDIBLE=$((count_CREDIBLE + 1))     ;;
        RESILIENT)  count_RESILIENT=$((count_RESILIENT + 1))   ;;
        ZERO_WASTE) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
    esac
done < <(printf '%s' "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
alert_fired=0

emit_alert() {
    local pillar="$1" count="$2" kind="$3" extra="$4"
    printf '{"ts":"%s","kind":"%s","pillar":"%s","count":%d,%s}\n' \
        "$emit_ts" "$kind" "$pillar" "$count" "$extra" >> "$AMBIENT"
    alert_fired=1
}

check_pillar() {
    local pillar="$1" count="$2"

    # Alert: pillar under-fed (< 2)
    if [[ "$count" -lt 2 ]]; then
        emit_alert "$pillar" "$count" "pillar_balance_alert" '"floor":2'
    fi

    # Alert: pillar overweight (> 50% of total)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            emit_alert "$pillar" "$count" "pillar_balance_overweight" "\"pct\":$pct"
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
