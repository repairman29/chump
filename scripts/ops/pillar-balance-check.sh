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
# non-empty AC (no TODO placeholder), depends_on=[].
#
# Bash 3.2 compatible — no declare -A / declare -n / mapfile / readarray.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"

# Resolve AMBIENT path; ensure parent dir exists.
REPO_TOP="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${AMBIENT:-$REPO_TOP/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")"

# Fetch all open gaps as JSON array.
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Bash-3.2-compatible counters (no associative arrays).
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0   # dash → underscore for varname; mapped back at emit time

# Parse each gap object emitted by `jq -c '.[]'`.
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(printf '%s' "$gap" | jq -r '.priority // ""' 2>/dev/null || true)
    effort=$(printf '%s' "$gap" | jq -r '.effort // ""' 2>/dev/null || true)
    ac=$(printf '%s' "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null || true)
    depends_on=$(printf '%s' "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null || true)
    title=$(printf '%s' "$gap" | jq -r '.title // ""' 2>/dev/null || true)

    # Must be P0 or P1.
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Must be xs or s effort.
    case "$effort" in xs|s) ;; *) continue ;; esac

    # No TODO acceptance_criteria (trim whitespace first).
    ac_trimmed="${ac#"${ac%%[![:space:]]*}"}"
    ac_trimmed="${ac_trimmed%"${ac_trimmed##*[![:space:]]}"}"
    case "$ac_trimmed" in
        TODO|todo|"To Do"|"to do"|FIXME|fixme) continue ;;
    esac

    # No blocking depends_on (must be empty array).
    if [[ "$depends_on" != "[]" && -n "$depends_on" ]]; then continue; fi

    # Determine pillar from title prefix (case-insensitive).
    title_lower=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
    case "$title_lower" in
        effective:*) count_EFFECTIVE=$((count_EFFECTIVE + 1)) ;;
        credible:*)  count_CREDIBLE=$((count_CREDIBLE + 1))  ;;
        resilient:*) count_RESILIENT=$((count_RESILIENT + 1)) ;;
        "zero-waste:"*) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
    esac
done < <(printf '%s' "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

# Total across the four pillars.
total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
alert_fired=0

# Emit alerts for each pillar using shell-variable indirection via eval (Bash 3.2).
for entry in "EFFECTIVE:EFFECTIVE" "CREDIBLE:CREDIBLE" "RESILIENT:RESILIENT" "ZERO-WASTE:ZERO_WASTE"; do
    pillar="${entry%%:*}"
    varname="${entry##*:}"
    count_var="count_${varname}"
    eval "count=\$$count_var"

    # Under-fed: count < 2.
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Overweight: count > 50% of total.
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
