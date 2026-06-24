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
# Bash 3.2 compatible (macOS /bin/bash — no declare -A/-n, mapfile, readarray).

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

# Ensure parent directory exists before writing to ambient
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Helper to extract pillar from title (case-insensitive prefix match)
get_pillar() {
    local title="$1"
    if echo "$title" | grep -qi '^EFFECTIVE:'; then echo "EFFECTIVE"
    elif echo "$title" | grep -qi '^CREDIBLE:'; then echo "CREDIBLE"
    elif echo "$title" | grep -qi '^RESILIENT:'; then echo "RESILIENT"
    elif echo "$title" | grep -qi '^ZERO-WASTE:'; then echo "ZERO-WASTE"
    else echo "OTHER"; fi
}

# Bash-3.2-compatible counters (no declare -A)
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0
count_OTHER=0

# Parse JSON and filter pickable gaps
while IFS= read -r gap; do
    if [[ -z "$gap" ]]; then continue; fi

    priority=$(echo "$gap" | jq -r '.priority // ""' 2>/dev/null || echo "")
    effort=$(echo "$gap" | jq -r '.effort // ""' 2>/dev/null || echo "")
    ac=$(echo "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || echo "")
    depends_on=$(echo "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || echo "[]")

    # Pickable: P0 or P1, effort xs or s
    case "$priority" in P0|P1) ;; *) continue ;; esac
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Skip TODO AC placeholders
    case "$(echo "$ac" | tr -d ' \t')" in
        TODO|Todo|todo|FIXME|fixme) continue ;;
    esac

    # Skip gaps with blocking depends_on (non-empty array)
    if [[ "$depends_on" != "[]" && -n "$depends_on" ]]; then continue; fi

    pillar=$(get_pillar "$(echo "$gap" | jq -r '.title // ""' 2>/dev/null || echo "")")
    case "$pillar" in
        EFFECTIVE)  count_EFFECTIVE=$((count_EFFECTIVE + 1)) ;;
        CREDIBLE)   count_CREDIBLE=$((count_CREDIBLE + 1)) ;;
        RESILIENT)  count_RESILIENT=$((count_RESILIENT + 1)) ;;
        ZERO-WASTE) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
        *)          count_OTHER=$((count_OTHER + 1)) ;;
    esac
done < <(echo "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

# Emit alerts
alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    varname="count_${p//-/_}"
    count=$(eval "echo \$${varname}")

    # Alert: pillar under-fed (< floor of 2)
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$p" "$count" >> "$AMBIENT"
        echo "WARN: pillar $p has $count pickable gaps (floor=2)" >&2
        alert_fired=1
    fi

    # Alert: pillar overweight (> 50% of total)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$p" "$count" "$pct" >> "$AMBIENT"
            echo "WARN: pillar $p is overweight ($pct% of pool)" >&2
            alert_fired=1
        fi
    fi
done

if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
