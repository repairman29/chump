#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Pickable gaps: status=open, priority P0|P1, effort xs|s,
#   non-empty non-TODO acceptance_criteria, no blocking depends_on.
#
# Exit 0 if healthy, non-zero if any alert fired.
#
# Bash 3.2 compatible (macOS ships 3.2 — no declare -A/-n/mapfile/readarray).

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON array
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Bash-3.2-compatible pillar counters (no declare -A)
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

# Parse JSON and filter pickable gaps
while IFS= read -r gap; do
    [ -z "$gap" ] && continue

    priority=$(printf '%s' "$gap" | jq -r '.priority // ""' 2>/dev/null || echo "")
    effort=$(printf '%s' "$gap"   | jq -r '.effort // ""'   2>/dev/null || echo "")
    ac=$(printf '%s' "$gap"       | jq -r '.acceptance_criteria // ""' 2>/dev/null || echo "")
    depends=$(printf '%s' "$gap"  | jq -r '.depends_on // "[]"'        2>/dev/null || echo "[]")
    title=$(printf '%s' "$gap"    | jq -r '.title // ""'                2>/dev/null || echo "")

    # Must be P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Must be xs or s effort
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Must have non-TODO acceptance criteria
    ac_trimmed=$(printf '%s' "$ac" | tr -d '[:space:]')
    [ -z "$ac_trimmed" ] && continue
    case "$ac_trimmed" in TODO*|todo*|FIXME*|fixme*) continue ;; esac

    # Must have no blocking depends_on (empty array or truly empty)
    if [ "$depends" != "[]" ] && [ -n "$depends" ]; then continue; fi

    # Map title prefix to pillar
    title_upper=$(printf '%s' "$title" | tr '[:lower:]' '[:upper:]')
    case "$title_upper" in
        EFFECTIVE:*) count_EFFECTIVE=$((count_EFFECTIVE+1)) ;;
        CREDIBLE:*)  count_CREDIBLE=$((count_CREDIBLE+1))  ;;
        RESILIENT:*) count_RESILIENT=$((count_RESILIENT+1)) ;;
        ZERO-WASTE:*) count_ZERO_WASTE=$((count_ZERO_WASTE+1)) ;;
    esac
done < <(printf '%s' "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
alert_fired=0

# Emit alerts for each pillar
for pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    # Map pillar name to variable (ZERO-WASTE → count_ZERO_WASTE)
    varname="count_$(printf '%s' "$pillar" | tr '-' '_')"
    count=$(eval "printf '%s' \"\$$varname\"")

    # Under-fed: count < floor (2)
    if [ "$count" -lt 2 ]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Overweight: count > 50% of total pickable
    if [ "$total_pickable" -gt 0 ]; then
        pct=$((count * 100 / total_pickable))
        if [ "$pct" -gt 50 ]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$pillar" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
done

exit "$alert_fired"
