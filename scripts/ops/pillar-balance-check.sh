#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Bash 3.2 compatible (macOS /bin/bash): no declare -A/-n, mapfile, readarray.
#
# Pickable: status=open, priority P0|P1, effort xs|s,
# non-empty / non-TODO acceptance_criteria, no blocking depends_on.
#
# Exit 0 if healthy, non-zero if any alert fired.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${AMBIENT:-$_REPO_ROOT/.chump-locks/ambient.jsonl}"

# Ensure .chump-locks/ dir exists before any >> writes (AC blocker #2 from INFRA-902).
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON array
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Per-pillar pickable counters (Bash-3.2: plain vars, no assoc arrays)
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

# Parse each gap and count pickable gaps by pillar
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(printf '%s' "$gap" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("priority",""))' 2>/dev/null || echo "")
    effort=$(printf '%s' "$gap" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("effort",""))' 2>/dev/null || echo "")
    ac=$(printf '%s' "$gap" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("acceptance_criteria",""))' 2>/dev/null || echo "")
    depends_on=$(printf '%s' "$gap" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("depends_on","[]"))' 2>/dev/null || echo "[]")
    title=$(printf '%s' "$gap" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("title",""))' 2>/dev/null || echo "")

    # Must be P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac

    # Must be xs or s effort
    case "$effort" in xs|s) ;; *) continue ;; esac

    # Must have non-empty, non-TODO acceptance criteria
    ac_trimmed=$(printf '%s' "$ac" | tr -d '[:space:]')
    if [[ -z "$ac_trimmed" ]]; then continue; fi
    case "$(printf '%s' "$ac" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        todo|todo:*|fixme|fixme:*) continue ;;
    esac

    # Must have no blocking depends_on (empty array or empty string)
    case "$depends_on" in "[]"|""|"[[]]") ;; *) continue ;; esac

    # Extract pillar from title prefix
    title_upper=$(printf '%s' "$title" | tr '[:lower:]' '[:upper:]')
    case "$title_upper" in
        EFFECTIVE:*) count_EFFECTIVE=$((count_EFFECTIVE + 1)) ;;
        CREDIBLE:*)  count_CREDIBLE=$((count_CREDIBLE + 1)) ;;
        RESILIENT:*) count_RESILIENT=$((count_RESILIENT + 1)) ;;
        ZERO-WASTE:*) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
    esac
done < <(printf '%s' "$ALL_GAPS" | python3 -c 'import json,sys; [print(json.dumps(g)) for g in json.load(sys.stdin)]' 2>/dev/null || true)

# Total pickable across the four pillars
total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

emit_ts=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
alert_fired=0

check_pillar() {
    local pillar="$1"
    local count="$2"

    # Under-fed alert (< 2)
    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    # Overweight alert (> 50% of total)
    if [[ "$total_pickable" -gt 0 ]]; then
        pct=$((count * 100 / total_pickable))
        if [[ "$pct" -gt 50 ]]; then
            printf '{"ts":"%s","kind":"pillar_balance_overweight","pillar":"%s","count":%d,"pct":%d}\n' \
                "$emit_ts" "$pillar" "$count" "$pct" >> "$AMBIENT"
            alert_fired=1
        fi
    fi
}

check_pillar "EFFECTIVE"  "$count_EFFECTIVE"
check_pillar "CREDIBLE"   "$count_CREDIBLE"
check_pillar "RESILIENT"  "$count_RESILIENT"
check_pillar "ZERO-WASTE" "$count_ZERO_WASTE"

if [[ "$alert_fired" -eq 1 ]]; then
    exit 1
fi
exit 0
