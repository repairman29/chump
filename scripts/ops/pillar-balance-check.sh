#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Pillar balance health check. Counts open pickable gaps per pillar
# (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE) and emits alerts to
# ambient.jsonl when any pillar is under-fed (< 2) or overweight (> 50%).
#
# Bash 3.2 compatible — no declare -A / mapfile / readarray.
# Exit 0 if healthy, non-zero if any alert fired.
#
# Pickable gaps: status=open, priority P0|P1, effort xs|s,
# no TODO acceptance_criteria, no blocking depends_on.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${AMBIENT:-$_ROOT/.chump-locks/ambient.jsonl}"

# Ensure the ambient directory exists before appending.
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# Bash-3.2-safe pillar counters (no declare -A)
count_EFFECTIVE=0
count_CREDIBLE=0
count_RESILIENT=0
count_ZERO_WASTE=0

# Helper: check if an AC is a TODO placeholder
is_todo_ac() {
    local ac="$1"
    case "$ac" in
        [[:space:]]*TODO*|TODO*|[[:space:]]*To\ [Dd]o*|To\ [Dd]o*|[[:space:]]*FIXME*|FIXME*) return 0 ;;
        *) return 1 ;;
    esac
}

# Parse JSON and filter pickable gaps
while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue

    priority=$(printf '%s' "$gap" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("priority",""))' 2>/dev/null || echo "")
    effort=$(printf '%s' "$gap" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("effort",""))' 2>/dev/null || echo "")
    ac=$(printf '%s' "$gap" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("acceptance_criteria",""))' 2>/dev/null || echo "")
    depends_on=$(printf '%s' "$gap" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("depends_on","[]"))' 2>/dev/null || echo "[]")
    title=$(printf '%s' "$gap" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("title",""))' 2>/dev/null || echo "")

    # Pickable: P0 or P1
    case "$priority" in P0|P1) ;; *) continue ;; esac
    # Pickable: effort xs or s
    case "$effort" in xs|s) ;; *) continue ;; esac
    # Skip TODO acceptance_criteria
    if is_todo_ac "$ac"; then continue; fi
    # Skip if blocking depends_on (non-empty, non-trivial)
    if [[ "$depends_on" != "[]" && -n "$depends_on" && "$depends_on" != "null" ]]; then continue; fi

    # Classify by pillar prefix (case-insensitive match)
    title_upper=$(printf '%s' "$title" | tr '[:lower:]' '[:upper:]')
    case "$title_upper" in
        EFFECTIVE:*) count_EFFECTIVE=$((count_EFFECTIVE + 1)) ;;
        CREDIBLE:*)  count_CREDIBLE=$((count_CREDIBLE + 1)) ;;
        RESILIENT:*) count_RESILIENT=$((count_RESILIENT + 1)) ;;
        ZERO-WASTE:*) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
        # OTHER — not counted toward pillar pool
    esac
done < <(printf '%s' "$ALL_GAPS" | python3 -c 'import sys,json; [print(__import__("json").dumps(g)) for g in json.load(sys.stdin)]' 2>/dev/null || true)

# Total pickable across the four pillars
total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)

for pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    # Fetch count via indirect variable name (Bash 3.2 compatible)
    varname="count_${pillar//-/_}"
    count=$(eval "echo \${$varname:-0}")

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
