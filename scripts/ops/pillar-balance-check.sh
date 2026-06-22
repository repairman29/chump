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
# Bash 3.2 compatible (macOS /bin/bash): no declare -A/-n, no mapfile/readarray.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
REPO_ROOT="${CHUMP_WORKTREE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# Ensure ambient directory exists
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Pillar counts — individual variables for Bash 3.2 (no declare -A)
EFFECTIVE_count=0
CREDIBLE_count=0
RESILIENT_count=0
ZERO_WASTE_count=0

# Parse JSON and filter pickable gaps
while IFS= read -r gap; do
    if [ -z "$gap" ]; then continue; fi

    priority=$(printf '%s' "$gap" | jq -r '.priority // ""' 2>/dev/null || true)
    effort=$(printf '%s' "$gap" | jq -r '.effort // ""' 2>/dev/null || true)
    ac=$(printf '%s' "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || true)
    depends_on=$(printf '%s' "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || true)
    title=$(printf '%s' "$gap" | jq -r '.title // ""' 2>/dev/null || true)

    # Check priority: P0 or P1
    case "$priority" in
        P0|P1) ;;
        *) continue ;;
    esac

    # Check effort: xs or s
    case "$effort" in
        xs|s) ;;
        *) continue ;;
    esac

    # Skip if AC is a TODO placeholder
    ac_trimmed=$(printf '%s' "$ac" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    case "$ac_trimmed" in
        TODO|todo|"To Do"|"to do"|FIXME|fixme|"TODO: "*|"TODO "*) continue ;;
    esac

    # Skip if depends_on is non-empty array (blocked)
    if [ "$depends_on" != "[]" ] && [ -n "$depends_on" ] && [ "$depends_on" != "null" ]; then
        continue
    fi

    # Determine pillar from title prefix (case-sensitive matching on prefix)
    if printf '%s' "$title" | grep -qi '^EFFECTIVE:'; then
        EFFECTIVE_count=$((EFFECTIVE_count + 1))
    elif printf '%s' "$title" | grep -qi '^CREDIBLE:'; then
        CREDIBLE_count=$((CREDIBLE_count + 1))
    elif printf '%s' "$title" | grep -qi '^RESILIENT:'; then
        RESILIENT_count=$((RESILIENT_count + 1))
    elif printf '%s' "$title" | grep -qi '^ZERO-WASTE:'; then
        ZERO_WASTE_count=$((ZERO_WASTE_count + 1))
    fi
done < <(printf '%s' "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

# Calculate total pickable (excluding OTHER)
total_pickable=$((EFFECTIVE_count + CREDIBLE_count + RESILIENT_count + ZERO_WASTE_count))

# Emit alerts
alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    varname=$(printf '%s' "$pillar" | tr '-' '_')
    eval "count=\${${varname}_count}"

    # Alert 1: Pillar under-fed (< 2)
    if [ "$count" -lt 2 ]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Alert 2: Pillar overweight (> 50% of total)
    if [ "$total_pickable" -gt 0 ]; then
        pct=$((count * 100 / total_pickable))
        if [ "$pct" -gt 50 ]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$pillar" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
done

if [ "$alert_fired" -eq 1 ]; then
    exit 1
fi
exit 0
