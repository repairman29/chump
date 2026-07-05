#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Exit 0 if healthy, non-zero if any alert fired.
#
# Pickable: status=open, priority P0|P1, effort xs|s,
#           no TODO acceptance_criteria, no blocking depends_on.
#
# Bash-3.2 compatible: no declare -A/-n, no mapfile, no readarray.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

mkdir -p "$(dirname "$AMBIENT")"

ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

cnt_EFFECTIVE=0
cnt_CREDIBLE=0
cnt_RESILIENT=0
cnt_ZERO_WASTE=0

while IFS= read -r gap; do
    if [[ -z "$gap" ]]; then continue; fi

    priority=$(echo "$gap" | jq -r '.priority // ""' 2>/dev/null || echo "")
    effort=$(echo "$gap" | jq -r '.effort // ""' 2>/dev/null || echo "")
    ac=$(echo "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || echo "")
    depends_on=$(echo "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || echo "[]")
    title=$(echo "$gap" | jq -r '.title // ""' 2>/dev/null || echo "")

    # Pickable: P0 or P1
    if [[ ! "$priority" =~ ^P[01]$ ]]; then continue; fi
    # Pickable: effort xs or s
    if [[ ! "$effort" =~ ^(xs|s)$ ]]; then continue; fi
    # Pickable: no TODO AC
    if echo "$ac" | grep -qiE '^\s*(TODO|to do|fixme)\s*$'; then continue; fi
    # Pickable: no blocking depends_on
    if [[ "$depends_on" != "[]" ]] && [[ -n "$depends_on" ]]; then continue; fi

    # Classify by pillar prefix (case-insensitive)
    if echo "$title" | grep -qiE '^EFFECTIVE:'; then
        cnt_EFFECTIVE=$((cnt_EFFECTIVE + 1))
    elif echo "$title" | grep -qiE '^CREDIBLE:'; then
        cnt_CREDIBLE=$((cnt_CREDIBLE + 1))
    elif echo "$title" | grep -qiE '^RESILIENT:'; then
        cnt_RESILIENT=$((cnt_RESILIENT + 1))
    elif echo "$title" | grep -qiE '^ZERO-WASTE:'; then
        cnt_ZERO_WASTE=$((cnt_ZERO_WASTE + 1))
    fi
done < <(echo "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((cnt_EFFECTIVE + cnt_CREDIBLE + cnt_RESILIENT + cnt_ZERO_WASTE))

alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    var="cnt_${pillar//-/_}"
    count="${!var}"

    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$pillar" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
done

if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
