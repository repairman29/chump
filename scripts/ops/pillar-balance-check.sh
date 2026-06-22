#!/usr/bin/env bash
# scripts/ops/pillar-balance-check.sh — INFRA-902
# Pillar balance analyzer: counts pickable open gaps per pillar, emits alerts
# when any pillar is under-stocked (< floor=2) or overweight (> 50% of pool).
#
# Bash 3.2 compatible — no declare -A, no mapfile, no readarray, no -n namerefs.
#
# Usage:
#   pillar-balance-check.sh           # human-readable + exit 1 on any alert
#   pillar-balance-check.sh --json    # JSON output
#   pillar-balance-check.sh --dry-run # compute + print, skip ambient emit
#
# Environment:
#   CHUMP_BIN              path to chump binary (default: chump)
#   CHUMP_LOCK_DIR         override .chump-locks/ directory
#   CHUMP_AMBIENT_LOG      override ambient.jsonl path
#   CHUMP_REPO             override repo root (used for CHUMP_HOME / state.db)
#
# Emits:
#   kind=pillar_balance_alert       when pillar count < floor (2)
#   kind=pillar_balance_overweight  when pillar count > 50% of total pickable
#
# scanner-anchor: "kind":"pillar_balance_alert"
# scanner-anchor: "kind":"pillar_balance_overweight"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
CHUMP_BIN="${CHUMP_BIN:-chump}"

JSON=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    JSON=1;    shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "pillar-balance-check: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Ensure ambient dir exists before any >> writes.
mkdir -p "$LOCK_DIR"

# Fetch open gaps as JSON — fall back to empty array on error.
GAPS_JSON=$("$CHUMP_BIN" gap list --status open --json 2>/dev/null) || GAPS_JSON="[]"

# Write gaps JSON to a temp file so python3 can read it without heredoc
# variable-expansion issues.
_TMP_GAPS="$(mktemp)"
trap 'rm -f "$_TMP_GAPS"' EXIT
printf '%s' "$GAPS_JSON" > "$_TMP_GAPS"

# Count pickable gaps per pillar.
# Pickable = P0|P1, effort xs|s|m (matches the existing pillar-balance Rust logic).
# Pillar detection by title keyword: EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE.
_ANALYSIS=$(python3 - "$_TMP_GAPS" <<'PYEOF'
import sys, json

try:
    gaps = json.load(open(sys.argv[1]))
except Exception:
    gaps = []

# Handle both plain array and {gaps: [...]} wrapper from --domain mode.
if isinstance(gaps, dict) and 'gaps' in gaps:
    gaps = gaps['gaps']
if not isinstance(gaps, list):
    gaps = []

PILLARS = ['EFFECTIVE', 'CREDIBLE', 'RESILIENT', 'ZERO-WASTE']
PICKABLE_PRIORITIES = {'P0', 'P1'}
PICKABLE_EFFORTS    = {'xs', 's', 'm'}

counts = {p: 0 for p in PILLARS}
other  = 0
total  = 0

for g in gaps:
    if g.get('status') != 'open':
        continue
    if g.get('priority', '') not in PICKABLE_PRIORITIES:
        continue
    if g.get('effort', '') not in PICKABLE_EFFORTS:
        continue
    total += 1
    title_up = g.get('title', '').upper()
    assigned = False
    for p in PILLARS:
        if p in title_up:
            counts[p] += 1
            assigned = True
            break
    if not assigned:
        other += 1

# Output as KEY=VALUE lines — Bash 3.2 safe, no special chars in keys/values.
print("total=" + str(total))
print("eff="   + str(counts['EFFECTIVE']))
print("cred="  + str(counts['CREDIBLE']))
print("res="   + str(counts['RESILIENT']))
print("zw="    + str(counts['ZERO-WASTE']))
print("other=" + str(other))
PYEOF
)

# Parse KEY=VALUE output — Bash 3.2 compatible (no declare -A).
_total=0
_eff=0
_cred=0
_res=0
_zw=0
_other=0

while IFS='=' read -r _k _v; do
    case "$_k" in
        total) _total="${_v:-0}" ;;
        eff)   _eff="${_v:-0}"   ;;
        cred)  _cred="${_v:-0}"  ;;
        res)   _res="${_v:-0}"   ;;
        zw)    _zw="${_v:-0}"    ;;
        other) _other="${_v:-0}" ;;
    esac
done <<EOF
$_ANALYSIS
EOF

ALERTS=0
_TS="$(now_ts)"

# Emit a single ambient event line.
_emit() {
    local _line="$1"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        printf '%s\n' "$_line" >> "$AMBIENT"
    fi
}

# Check one pillar against floor and overweight thresholds.
_check() {
    local _name="$1"
    local _count="$2"
    local _floor=2

    if [[ "$_count" -lt "$_floor" ]]; then
        ALERTS=$((ALERTS+1))
        # scanner-anchor: "kind":"pillar_balance_alert"
        _emit "{\"ts\":\"$_TS\",\"kind\":\"pillar_balance_alert\",\"pillar\":\"$_name\",\"count\":$_count,\"floor\":$_floor}"
        if [[ "$JSON" -eq 0 ]]; then
            echo "ALERT: pillar $_name underweight: $_count pickable (floor=$_floor)"
        fi
    fi

    if [[ "$_total" -gt 0 ]]; then
        # Integer > 50%: count * 2 > total
        local _doubled=$((_count * 2))
        if [[ "$_doubled" -gt "$_total" ]]; then
            local _pct=$((_count * 100 / _total))
            ALERTS=$((ALERTS+1))
            # scanner-anchor: "kind":"pillar_balance_overweight"
            _emit "{\"ts\":\"$_TS\",\"kind\":\"pillar_balance_overweight\",\"pillar\":\"$_name\",\"count\":$_count,\"total\":$_total,\"pct\":$_pct}"
            if [[ "$JSON" -eq 0 ]]; then
                echo "ALERT: pillar $_name overweight: $_count/$_total (${_pct}% > 50%)"
            fi
        fi
    fi
}

_check "EFFECTIVE"  "$_eff"
_check "CREDIBLE"   "$_cred"
_check "RESILIENT"  "$_res"
_check "ZERO-WASTE" "$_zw"

if [[ "$JSON" -eq 1 ]]; then
    python3 -c "
import json
print(json.dumps({
    'total_pickable': $_total,
    'pillars': {
        'EFFECTIVE':  $_eff,
        'CREDIBLE':   $_cred,
        'RESILIENT':  $_res,
        'ZERO-WASTE': $_zw,
    },
    'other': $_other,
    'alerts_fired': $ALERTS,
}, indent=2))
"
else
    echo "[pillar-balance-check] total_pickable=$_total EFFECTIVE=$_eff CREDIBLE=$_cred RESILIENT=$_res ZERO-WASTE=$_zw other=$_other"
    if [[ "$ALERTS" -eq 0 ]]; then
        echo "OK: pillar balance within thresholds"
    fi
fi

[[ "$ALERTS" -eq 0 ]]
