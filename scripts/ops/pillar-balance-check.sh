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
# no TODO acceptance_criteria, no blocking depends_on.
#
# Bash 3.2 compatible (macOS /bin/bash) — no declare -A/-n, no mapfile.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

# Ensure ambient directory exists before any >> writes
mkdir -p "$(dirname "$AMBIENT")"

# Read all open gaps as JSON array
ALL_GAPS=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null || echo '[]')

# ── helpers ──────────────────────────────────────────────────────────────────

is_todo_ac() {
    echo "$1" | grep -qiE '^\s*(TODO|[Tt]o [Dd]o|fixme|FIXME)\s*$'
}

get_pillar() {
    local title="$1"
    if echo "$title" | grep -qiE '^EFFECTIVE:'; then   echo "EFFECTIVE"
    elif echo "$title" | grep -qiE '^CREDIBLE:';   then echo "CREDIBLE"
    elif echo "$title" | grep -qiE '^RESILIENT:';  then echo "RESILIENT"
    elif echo "$title" | grep -qiE '^ZERO-WASTE:'; then echo "ZERO-WASTE"
    else echo "OTHER"
    fi
}

# ── count pickable gaps per pillar (Bash 3.2: no associative arrays) ─────────

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

    # Must be P0 or P1
    echo "$priority" | grep -qE '^P[01]$' || continue
    # Must be xs or s effort
    echo "$effort" | grep -qE '^(xs|s)$' || continue
    # Must not have a TODO AC
    is_todo_ac "$ac" && continue
    # Must not have blocking deps
    if [[ "$depends_on" != "[]" ]] && [[ "$depends_on" != "null" ]] && [[ -n "$depends_on" ]]; then
        continue
    fi

    title=$(echo "$gap" | jq -r '.title // ""' 2>/dev/null || echo "")
    pillar=$(get_pillar "$title")

    case "$pillar" in
        EFFECTIVE)  count_EFFECTIVE=$((count_EFFECTIVE + 1)) ;;
        CREDIBLE)   count_CREDIBLE=$((count_CREDIBLE + 1)) ;;
        RESILIENT)  count_RESILIENT=$((count_RESILIENT + 1)) ;;
        ZERO-WASTE) count_ZERO_WASTE=$((count_ZERO_WASTE + 1)) ;;
    esac
done < <(echo "$ALL_GAPS" | jq -c '.[]' 2>/dev/null || true)

total_pickable=$((count_EFFECTIVE + count_CREDIBLE + count_RESILIENT + count_ZERO_WASTE))

# ── emit alerts ───────────────────────────────────────────────────────────────

alert_fired=0
emit_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

check_pillar() {
    local pillar="$1"
    local count="$2"

    if [[ "$count" -lt 2 ]]; then
        printf '{"ts":"%s","kind":"pillar_balance_alert","pillar":"%s","count":%d,"floor":2}\n' \
            "$emit_ts" "$pillar" "$count" >> "$AMBIENT"
        alert_fired=1
    fi

    if [[ "$total_pickable" -gt 0 ]]; then
        local pct=$(( count * 100 / total_pickable ))
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

# ── summary output ─────────────────────────────────────────────────────────────

echo "[pillar-balance] pickable=$total_pickable EFFECTIVE=$count_EFFECTIVE CREDIBLE=$count_CREDIBLE RESILIENT=$count_RESILIENT ZERO-WASTE=$count_ZERO_WASTE"

if [[ "$alert_fired" -eq 1 ]]; then
    echo "[pillar-balance] ALERTS FIRED — see $AMBIENT"
    exit 1
fi

exit 0
