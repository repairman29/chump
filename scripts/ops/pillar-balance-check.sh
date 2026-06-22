#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Pickable gaps: status=open, priority P0|P1, effort xs|s,
# no TODO acceptance_criteria, no blocking depends_on.
#
# Exit 0 if healthy, non-zero if any alert fired.
#
# Bash 3.2 compatible — no declare -A/-n, no mapfile, no readarray.
# Verified on macOS /bin/bash (3.2) and Linux bash 5.x.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

# Ensure the ambient directory exists before any append.
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON array.
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Pillar counters — named variables instead of associative array (Bash 3.2).
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

# Parse each gap and tally pickable ones.
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(printf '%s' "$gap" | jq -r '.priority // ""' 2>/dev/null || echo "")
    effort=$(printf '%s' "$gap"   | jq -r '.effort // ""' 2>/dev/null   || echo "")
    ac=$(printf '%s' "$gap"       | jq -r '.acceptance_criteria // ""' 2>/dev/null || echo "")
    depends_on=$(printf '%s' "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || echo "[]")
    title=$(printf '%s' "$gap"    | jq -r '.title // ""' 2>/dev/null    || echo "")

    # Pickable criteria: P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac
    # Pickable criteria: effort xs or s
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Skip TODO / empty ACs.
    trimmed_ac=$(printf '%s' "$ac" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    [[ -z "$trimmed_ac" ]] && continue
    case "$trimmed_ac" in TODO*|todo*|FIXME*|fixme*|"To Do"*|"to do"*) continue ;; esac

    # Skip if has blocking depends_on (non-empty JSON array).
    if [[ "$depends_on" != "[]" ]] && [[ -n "$depends_on" ]]; then continue; fi

    # Tally by pillar prefix (case-insensitive via grep -i for robustness).
    case "$title" in
        EFFECTIVE:*|effective:*)         count_EFFECTIVE=$((count_EFFECTIVE + 1)) ;;
        CREDIBLE:*|credible:*)           count_CREDIBLE=$((count_CREDIBLE + 1)) ;;
        RESILIENT:*|resilient:*)         count_RESILIENT=$((count_RESILIENT + 1)) ;;
        "ZERO-WASTE:"*|"zero-waste:"*)   count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
    esac
done < <(printf '%s\n' "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
alert_fired=0

# Emit alerts for a single pillar.
check_pillar() {
    local name="$1" count="$2"

    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$name" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    if [[ "$total_pickable" -gt 0 ]]; then
        local pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$name" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
}

check_pillar "EFFECTIVE"  "$count_EFFECTIVE"
check_pillar "CREDIBLE"   "$count_CREDIBLE"
check_pillar "RESILIENT"  "$count_RESILIENT"
check_pillar "ZERO-WASTE" "$count_ZERO_WASTE"

printf 'Pillar counts — EFFECTIVE:%d CREDIBLE:%d RESILIENT:%d ZERO-WASTE:%d (total pickable:%d)\n' \
    "$count_EFFECTIVE" "$count_CREDIBLE" "$count_RESILIENT" "$count_ZERO_WASTE" "$total_pickable"

if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
