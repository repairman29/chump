#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Bash 3.2 compatible (macOS /bin/bash — no declare -A/n, no mapfile/readarray).
# Exit 0 if healthy, non-zero if any alert fired.
#
# Pickable gaps: status=open, priority P0|P1, effort xs|s,
# no TODO acceptance_criteria, no blocking depends_on.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Respect CHUMP_REPO (may point at the main checkout from a linked worktree)
AMBIENT="${AMBIENT:-${CHUMP_REPO:-$REPO_ROOT}/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Bash 3.2 compatible per-pillar counters (no declare -A)
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

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
    # Skip TODO/FIXME acceptance criteria (vague, not pickable)
    if echo "$ac" | grep -qiE '^\s*(TODO|FIXME|To Do)\s*:?\s*$'; then continue; fi
    # Skip if has blocking depends_on (non-empty array)
    if [[ "$depends_on" != "[]" && -n "$depends_on" && "$depends_on" != "null" ]]; then continue; fi

    # Classify by pillar prefix (case-insensitive match on leading "PILLAR:")
    if echo "$title" | grep -qi '^EFFECTIVE:'; then
        count_EFFECTIVE=$((count_EFFECTIVE+1))
    elif echo "$title" | grep -qi '^CREDIBLE:'; then
        count_CREDIBLE=$((count_CREDIBLE+1))
    elif echo "$title" | grep -qi '^RESILIENT:'; then
        count_RESILIENT=$((count_RESILIENT+1))
    elif echo "$title" | grep -qi '^ZERO-WASTE:'; then
        count_ZERO_WASTE=$((count_ZERO_WASTE+1))
    fi
done < <(echo "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))
alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    case "$p" in
        EFFECTIVE)  count=$count_EFFECTIVE ;;
        CREDIBLE)   count=$count_CREDIBLE ;;
        RESILIENT)  count=$count_RESILIENT ;;
        ZERO-WASTE) count=$count_ZERO_WASTE ;;
        *)          count=0 ;;
    esac

    # Alert: pillar under-fed (< floor of 2)
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$p" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Alert: pillar overweight (> 50% of total pickable pool)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$p" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
done

[[ "$alert_fired" -eq 1 ]] && exit 1
exit 0
