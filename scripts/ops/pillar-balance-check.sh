#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Compatible with Bash 3.2+ (macOS default). No declare -A / readarray / mapfile.
#
# Exit 0 if healthy, non-zero if any alert fired.
#
# Pickable gaps are: status=open, priority P0|P1, effort xs|s,
# no TODO acceptance_criteria, no blocking depends_on.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# Ensure ambient directory exists
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Pillar counters (Bash 3.2 compatible — no declare -A)
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

# Parse JSON and filter pickable gaps using jq
while IFS= read -r gap; do
    if [[ -z "$gap" ]]; then continue; fi

    priority=$(printf '%s' "$gap" | jq -r '.priority // ""' 2>/dev/null || echo "")
    effort=$(printf '%s' "$gap" | jq -r '.effort // ""' 2>/dev/null || echo "")
    ac=$(printf '%s' "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || echo "")
    depends_on=$(printf '%s' "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || echo "[]")
    title=$(printf '%s' "$gap" | jq -r '.title // ""' 2>/dev/null || echo "")

    # Must be P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Must be xs or s effort
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Skip TODO AC placeholders
    ac_trimmed=$(printf '%s' "$ac" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    case "$ac_trimmed" in
        TODO|todo|"To Do"|"to do"|FIXME|fixme|"") continue ;;
    esac

    # Skip gaps with blocking depends_on (non-empty, non-null array)
    if [[ "$depends_on" != "[]" ]] && [[ "$depends_on" != "null" ]] && [[ -n "$depends_on" ]]; then
        continue
    fi

    # Classify by pillar prefix (case-insensitive)
    title_upper=$(printf '%s' "$title" | tr '[:lower:]' '[:upper:]')
    case "$title_upper" in
        EFFECTIVE:*) count_EFFECTIVE=$((count_EFFECTIVE + 1)) ;;
        CREDIBLE:*)  count_CREDIBLE=$((count_CREDIBLE + 1)) ;;
        RESILIENT:*) count_RESILIENT=$((count_RESILIENT + 1)) ;;
        ZERO-WASTE:*) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
    esac

done < <(printf '%s' "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

# Total pickable across the 4 pillars
total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

# Emit alerts
alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    # Bash 3.2: indirect variable reference via eval
    var_name="count_$(printf '%s' "$p" | tr '-' '_')"
    eval "count=\$$var_name"

    # Alert 1: Pillar under-fed (< 2)
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$p" "$count" >> "$AMBIENT"
        echo "[pillar-balance] WARN: $p has $count pickable gaps (floor=2)" >&2
        alert_fired=1
    fi

    # Alert 2: Pillar overweight (> 50% of total)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$p" "$count" "$pct" >> "$AMBIENT"
            echo "[pillar-balance] WARN: $p is overweight at ${pct}% of pickable pool" >&2
            alert_fired=1
        fi
    fi
done

echo "[pillar-balance] pickable: EFFECTIVE=$count_EFFECTIVE CREDIBLE=$count_CREDIBLE RESILIENT=$count_RESILIENT ZERO-WASTE=$count_ZERO_WASTE total=$total_pickable"

if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
