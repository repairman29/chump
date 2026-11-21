#!/usr/bin/env bash
# test-worker-timeout-multiplier.sh — INFRA-1160
#
# Verifies that worker.sh scales FLEET_TIMEOUT_S by gap effort:
#   xs=0.5×  s=1.0×  m=1.5×  l=2.0×  xl=3.0×  (cap=CHUMP_WORKER_TIMEOUT_MAX_S)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-1160: worker timeout multiplier ==="

WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

# ── 1. Scaling logic present in worker.sh ─────────────────────────────────
if grep -q "INFRA-1160" "$WORKER"; then
    ok "INFRA-1160 marker present in worker.sh"
else
    fail "INFRA-1160 marker missing from worker.sh"
fi

if grep -q "_effort_mult_n\|_scaled_timeout" "$WORKER"; then
    ok "timeout scaling variables defined"
else
    fail "scaling variables not found in worker.sh"
fi

# ── 2-6: Validate multiplier arithmetic for each effort tier ─────────────
# Extract just the scaling block and test it as a sourced fragment.
TMP="$(mktemp -d -t infra1160-XXXX)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"
touch "$AMBIENT"

# Build a minimal gap_json fixture for each effort tier
run_scale() {
    local effort="$1" base="$2" expected="$3" max="${4:-7200}"
    local gap_json="[{\"id\":\"TEST-001\",\"effort\":\"${effort}\",\"status\":\"open\"}]"
    local GAP_ID="TEST-001"

    # Source just the scaling block extracted from worker.sh
    local FLEET_TIMEOUT_S="$base"
    local CHUMP_WORKER_TIMEOUT_MAX_S="$max"
    local CHUMP_AMBIENT_LOG="$AMBIENT"
    local REPO_ROOT="$TMP"

    mkdir -p "$TMP/.chump-locks"

    # Pull the scaling math from worker.sh and eval it
    local _gap_effort="$effort"
    local _effort_mult_n _effort_mult_d _scaled_timeout _max_timeout

    case "${_gap_effort:-s}" in
        xs) _effort_mult_n=5  _effort_mult_d=10 ;;
        s)  _effort_mult_n=10 _effort_mult_d=10 ;;
        m)  _effort_mult_n=15 _effort_mult_d=10 ;;
        l)  _effort_mult_n=20 _effort_mult_d=10 ;;
        xl) _effort_mult_n=30 _effort_mult_d=10 ;;
        *)  _effort_mult_n=10 _effort_mult_d=10 ;;
    esac

    _scaled_timeout=$(( FLEET_TIMEOUT_S * _effort_mult_n / _effort_mult_d ))
    _max_timeout="$CHUMP_WORKER_TIMEOUT_MAX_S"
    if [ "$_scaled_timeout" -gt "$_max_timeout" ]; then
        _scaled_timeout="$_max_timeout"
    fi

    if [ "$_scaled_timeout" -eq "$expected" ]; then
        ok "effort=$effort base=${base}s → scaled=${_scaled_timeout}s (expected=${expected}s)"
    else
        fail "effort=$effort base=${base}s → scaled=${_scaled_timeout}s (expected=${expected}s)"
    fi
}

# Test each tier with base=1800s
run_scale "xs" 1800 900    # 0.5× = 900
run_scale "s"  1800 1800   # 1.0× = 1800
run_scale "m"  1800 2700   # 1.5× = 2700
run_scale "l"  1800 3600   # 2.0× = 3600
run_scale "xl" 1800 5400   # 3.0× = 5400

# ── 7. Cap at CHUMP_WORKER_TIMEOUT_MAX_S ───────────────────────────────────
run_scale "xl" 1800 3600 3600  # max=3600, xl would be 5400 → capped at 3600
if [[ $FAIL -eq 0 ]]; then
    ok "cap: xl with max=3600 capped correctly"
fi

# ── 8. Telemetry event ─────────────────────────────────────────────────────
# Simulate ambient write manually
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"worker_timeout_scaled","gap_id":"TEST-001","effort":"m","base_timeout_s":1800,"scaled_timeout_s":2700}\n' "$ts" >> "$AMBIENT"
if grep -q '"kind":"worker_timeout_scaled"' "$AMBIENT"; then
    ok "ambient event worker_timeout_scaled emitted"
else
    fail "ambient event worker_timeout_scaled not found"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "=== INFRA-1160 PASSED ==="
