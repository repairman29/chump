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
# Exit 0 = healthy, non-zero = alert(s) fired.
#
# Bash 3.2 compatible (macOS /bin/bash) — no declare -A/-n/mapfile/readarray.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
AMBIENT="${AMBIENT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/ambient.jsonl}"

# Ensure ambient directory exists before any '>>' write.
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON array.
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Per-pillar pickable counts — separate variables, no associative array.
cnt_eff=0
cnt_cred=0
cnt_res=0
cnt_zw=0

# Classify a gap's pillar from its title prefix.
get_pillar() {
    local title="$1"
    case "$title" in
        EFFECTIVE:*|effective:*)  echo "EFFECTIVE" ;;
        CREDIBLE:*|credible:*)    echo "CREDIBLE" ;;
        RESILIENT:*|resilient:*)  echo "RESILIENT" ;;
        ZERO-WASTE:*|zero-waste:*|ZERO_WASTE:*) echo "ZERO-WASTE" ;;
        *)                        echo "OTHER" ;;
    esac
}

# Returns 0 if the AC string is a TODO placeholder, 1 otherwise.
is_todo_ac() {
    local ac="$1"
    case "$ac" in
        *TODO*|*todo*|*fixme*|*FIXME*) return 0 ;;
        *) return 1 ;;
    esac
}

# Parse each gap from the JSON array and tally pickable counts.
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(printf '%s' "$gap" | jq -r '.priority // ""' 2>/dev/null) || priority=""
    effort=$(printf '%s' "$gap" | jq -r '.effort // ""' 2>/dev/null) || effort=""
    ac=$(printf '%s' "$gap" | jq -r '.acceptance_criteria // ""' 2>/dev/null) || ac=""
    depends_on=$(printf '%s' "$gap" | jq -r '.depends_on // "[]"' 2>/dev/null) || depends_on="[]"
    title=$(printf '%s' "$gap" | jq -r '.title // ""' 2>/dev/null) || title=""

    # Must be P0 or P1.
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Must be xs or s effort.
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Skip gaps with TODO AC.
    if is_todo_ac "$ac"; then continue; fi

    # Skip gaps with non-empty depends_on (blocking deps).
    if [[ "$depends_on" != "[]" && -n "$depends_on" ]]; then continue; fi

    pillar=$(get_pillar "$title")
    case "$pillar" in
        EFFECTIVE)  cnt_eff=$((cnt_eff + 1)) ;;
        CREDIBLE)   cnt_cred=$((cnt_cred + 1)) ;;
        RESILIENT)  cnt_res=$((cnt_res + 1)) ;;
        ZERO-WASTE) cnt_zw=$((cnt_zw + 1)) ;;
    esac
done < <(printf '%s' "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total=$((cnt_eff + cnt_cred + cnt_res + cnt_zw))
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
alert_fired=0

emit_alert() {
    local pillar="$1" count="$2"
    printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
        "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
    alert_fired=1
}

emit_overweight() {
    local pillar="$1" count="$2" pct="$3"
    printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
        "$emit_ts" "$pillar" "$count" "$pct" >> "$AMBIENT"
    alert_fired=1
}

# Check each pillar against floor (< 2) and ceiling (> 50%).
check_pillar() {
    local pillar="$1" count="$2"
    if [[ "$count" -lt 2 ]]; then
        emit_alert "$pillar" "$count"
    fi
    if [[ "$total" -gt 0 ]]; then
        local pct=$(( count * 100 / total ))
        if [[ "$pct" -gt 50 ]]; then
            emit_overweight "$pillar" "$count" "$pct"
        fi
    fi
}

check_pillar "EFFECTIVE"  "$cnt_eff"
check_pillar "CREDIBLE"   "$cnt_cred"
check_pillar "RESILIENT"  "$cnt_res"
check_pillar "ZERO-WASTE" "$cnt_zw"

if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
