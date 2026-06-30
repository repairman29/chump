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
# Bash-3.2 compatible (macOS default shell) — no declare -A/-n/mapfile/readarray.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

# Ensure the ambient log directory exists (BLOCKER fix)
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Per-pillar counters — Bash 3.2 compatible (no declare -A)
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

# Parse JSON and filter pickable gaps
while IFS= read -r gap; do
    if [[ -z "$gap" ]]; then continue; fi

    priority=$(printf '%s' "$gap" | jq -r '.priority // ""' 2>/dev/null || true)
    effort=$(printf '%s' "$gap" | jq -r '.effort // ""' 2>/dev/null || true)
    ac=$(printf '%s' "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || true)
    depends_on=$(printf '%s' "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || true)
    title=$(printf '%s' "$gap" | jq -r '.title // ""' 2>/dev/null || true)

    # Must be P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Must be xs or s effort
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Skip TODO acceptance_criteria
    case "$ac" in
        ''|*[Tt][Oo][Dd][Oo]*|*[Ff][Ii][Xx][Mm][Ee]*) continue ;;
    esac

    # Skip gaps with blocking dependencies (non-empty array)
    if [[ "$depends_on" != "[]" && -n "$depends_on" ]]; then continue; fi

    # Classify by pillar prefix in title (case-insensitive)
    title_upper=$(printf '%s' "$title" | tr '[:lower:]' '[:upper:]')
    case "$title_upper" in
        EFFECTIVE:*) count_EFFECTIVE=$((count_EFFECTIVE + 1)) ;;
        CREDIBLE:*)  count_CREDIBLE=$((count_CREDIBLE + 1)) ;;
        RESILIENT:*) count_RESILIENT=$((count_RESILIENT + 1)) ;;
        ZERO-WASTE:*) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
    esac

done < <(printf '%s' "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

# Total pickable across the 4 named pillars
total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    # Bash 3.2: indirect variable lookup via a sub-shell eval
    var="count_${pillar//-/_}"
    eval "count=\$$var"

    # Alert: under-fed (< 2)
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Alert: overweight (> 50% of total)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$pillar" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
done

exit "$alert_fired"
