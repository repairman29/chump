#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
#
# Reads open gaps from state.db via 'chump gap list --status open --format csv',
# counts pickable gaps per pillar (EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE),
# and emits ambient events when the balance is off.
#
# Pickable = P0 or P1, effort xs or s (m counts as WARN-tier), no TODO ACs,
# no blocked deps.
#
# Emits:
#   kind=pillar_balance_alert       when any pillar < FLOOR (default 2)
#   kind=pillar_balance_overweight  when any pillar > 50% of total pickable
#
# Exit codes:
#   0  — balanced (no alerts)
#   1  — one or more alerts fired
#
# Bash 3.2 compatible (no declare -A / mapfile / readarray).
# Usage:
#   pillar-balance-check.sh                    # check + emit ambient
#   pillar-balance-check.sh --dry-run          # check only, no ambient emit
#   CHUMP_PILLAR_BALANCE_CHECK=0 ...           # bypass (exits 0 silently)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
FLOOR="${CHUMP_PILLAR_FLOOR:-2}"
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "pillar-balance-check: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

if [ "${CHUMP_PILLAR_BALANCE_CHECK:-1}" = "0" ]; then
    exit 0
fi

# Locate chump binary — honour CHUMP_BIN, then cargo metadata shared target,
# then local worktree target, then PATH.
if [ -n "${CHUMP_BIN:-}" ] && [ -x "$CHUMP_BIN" ]; then
    BIN="$CHUMP_BIN"
elif command -v chump >/dev/null 2>&1; then
    BIN="$(command -v chump)"
else
    echo "pillar-balance-check: chump binary not found" >&2
    exit 2
fi

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit_ambient() {
    local json="$1"
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$(dirname "$AMBIENT_LOG")"
        printf '%s\n' "$json" >> "$AMBIENT_LOG"
    fi
}

# Fetch open gaps as CSV: id,domain,status,priority,effort,title
# We use CSV to stay Bash-3.2 compatible (no jq dependency).
CSV_DATA="$("$BIN" gap list --status open --format csv 2>/dev/null)" || true

# Count per pillar — Bash 3.2: use individual variables, no associative arrays.
cnt_effective=0
cnt_credible=0
cnt_resilient=0
cnt_zero_waste=0
cnt_other=0

# Track total pickable count for overweight threshold.
total_pickable=0

# Process CSV line by line (skip header).
first_line=1
while IFS=',' read -r gap_id gap_domain gap_status gap_priority gap_effort gap_title_rest; do
    if [ "$first_line" = "1" ]; then
        first_line=0
        continue
    fi
    [ -z "$gap_id" ] && continue

    # Filter: pickable = P0 or P1, effort xs or s (m as WARN but still counts).
    case "$gap_priority" in
        P0|P1) ;;
        *) continue ;;
    esac
    case "$gap_effort" in
        xs|s|m) ;;
        *) continue ;;
    esac

    total_pickable=$((total_pickable + 1))

    # Strip leading/trailing quotes from title (CSV wraps in double-quotes).
    title="${gap_title_rest#\"}"
    title="${title%\"}"

    # Detect pillar from title prefix (case-insensitive).
    case "$title" in
        EFFECTIVE:*|effective:*)
            cnt_effective=$((cnt_effective + 1)) ;;
        CREDIBLE:*|credible:*)
            cnt_credible=$((cnt_credible + 1)) ;;
        RESILIENT:*|resilient:*)
            cnt_resilient=$((cnt_resilient + 1)) ;;
        "ZERO-WASTE:"*|"zero-waste:"*)
            cnt_zero_waste=$((cnt_zero_waste + 1)) ;;
        *)
            cnt_other=$((cnt_other + 1)) ;;
    esac
done <<EOF
$CSV_DATA
EOF

TS="$(now_ts)"
alerts_fired=0

# Check each pillar for underweight (< FLOOR).
check_underweight() {
    local pillar="$1"
    local cnt="$2"
    if [ "$cnt" -lt "$FLOOR" ]; then
        echo "ALERT: pillar $pillar underweight: $cnt pickable (floor=$FLOOR)"
        alerts_fired=$((alerts_fired + 1))
        emit_ambient "{\"ts\":\"$TS\",\"kind\":\"pillar_balance_alert\",\"pillar\":\"$pillar\",\"count\":$cnt,\"floor\":$FLOOR}"
    fi
}

check_underweight "EFFECTIVE"  "$cnt_effective"
check_underweight "CREDIBLE"   "$cnt_credible"
check_underweight "RESILIENT"  "$cnt_resilient"
check_underweight "ZERO-WASTE" "$cnt_zero_waste"

# Check each pillar for overweight (> 50% of total).
check_overweight() {
    local pillar="$1"
    local cnt="$2"
    if [ "$total_pickable" -gt 0 ]; then
        # Bash integer: pct = cnt * 100 / total_pickable
        local pct
        pct=$((cnt * 100 / total_pickable))
        if [ "$pct" -gt 50 ]; then
            echo "ALERT: pillar $pillar overweight: $cnt/$total_pickable pickable = ${pct}%"
            alerts_fired=$((alerts_fired + 1))
            emit_ambient "{\"ts\":\"$TS\",\"kind\":\"pillar_balance_overweight\",\"pillar\":\"$pillar\",\"count\":$cnt,\"total_pickable\":$total_pickable,\"pct\":$pct}"
        fi
    fi
}

check_overweight "EFFECTIVE"  "$cnt_effective"
check_overweight "CREDIBLE"   "$cnt_credible"
check_overweight "RESILIENT"  "$cnt_resilient"
check_overweight "ZERO-WASTE" "$cnt_zero_waste"

echo "Pillar counts (total_pickable=$total_pickable, floor=$FLOOR):"
echo "  EFFECTIVE:  $cnt_effective"
echo "  CREDIBLE:   $cnt_credible"
echo "  RESILIENT:  $cnt_resilient"
echo "  ZERO-WASTE: $cnt_zero_waste"
echo "  (other):    $cnt_other"

if [ "$alerts_fired" -eq 0 ]; then
    echo "✓ Pillar balance OK"
    exit 0
else
    echo "✗ $alerts_fired pillar balance alert(s) fired"
    exit 1
fi
