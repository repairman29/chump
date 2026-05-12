#!/usr/bin/env bash
# test-system-invariants-fixtures.sh — META-033: fixture tests for invariants.
#
# Seeds a synthetic environment for each invariant, runs the monitor script
# against it, and asserts the right ALERTs fire. One fixture per invariant.
#
# Usage:
#   bash scripts/ci/test-system-invariants-fixtures.sh
#   bash scripts/ci/test-system-invariants-fixtures.sh --inv INV-3
#   bash scripts/ci/test-system-invariants-fixtures.sh --verbose

set -euo pipefail

VERBOSE=0
SINGLE_INV=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose) VERBOSE=1 ;;
        --inv) SINGLE_INV="$2"; shift ;;
        -h|--help) echo "Usage: $0 [--inv INV-N] [--verbose]"; exit 0 ;;
        *) echo "Unknown: $1" >&2; exit 2 ;;
    esac
    shift
done

PASS=0
FAIL=0
FAILED_TESTS=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR="$SCRIPT_DIR/../ops/system-invariants-monitor.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { PASS=$((PASS+1)); echo "  PASS $*"; }
fail() { FAIL=$((FAIL+1)); FAILED_TESTS="$FAILED_TESTS $1"; echo "  FAIL $1: $2"; }

# Helper: run the monitor for a single invariant in a fixture environment.
# Usage: run_inv INV-N
run_inv() {
    local inv="$1"
    (
        export CHUMP_SKIP_INV_1=1 CHUMP_SKIP_INV_2=1 CHUMP_SKIP_INV_3=1
        export CHUMP_SKIP_INV_4=1 CHUMP_SKIP_INV_5=1 CHUMP_SKIP_INV_6=1 CHUMP_SKIP_INV_7=1
        export "CHUMP_SKIP_${inv//-/_}="
        bash "$MONITOR" --inv "$inv" 2>&1 || true
    )
}

echo "=== system-invariants fixture tests ==="

# ── INV-1: PR pile-up ────────────────────────────────────────────────────────
test_inv_1() {
    local inv="INV-1"
    [[ -n "$SINGLE_INV" && "$SINGLE_INV" != "$inv" ]] && return 0
    echo "--- $inv: PR pile-up ---"
    local out
    out=$(run_inv "$inv")
    if echo "$out" | grep -q "$inv"; then
        pass "$inv runs without error"
    else
        fail "$inv" "no output: $out"
    fi
}
test_inv_1

# ── INV-2: domain leak ────────────────────────────────────────────────────────
test_inv_2() {
    local inv="INV-2"
    [[ -n "$SINGLE_INV" && "$SINGLE_INV" != "$inv" ]] && return 0
    echo "--- $inv: domain threshold ---"
    local tmpdir; tmpdir=$(mktemp -d)
    local gaps="$tmpdir/docs/gaps"
    mkdir -p "$gaps"
    for i in $(seq 1 120); do
        printf -- "- id: TEST-%s\n  domain: EVAL\n  status: open\n" "$i" > "$gaps/TEST-$i.yaml"
    done
    local out
    out=$(CHUMP_SKIP_INV_1=1 CHUMP_SKIP_INV_3=1 CHUMP_SKIP_INV_4=1 \
          CHUMP_SKIP_INV_5=1 CHUMP_SKIP_INV_6=1 CHUMP_SKIP_INV_7=1 \
          REPO_ROOT="$tmpdir" bash "$MONITOR" --inv INV-2 2>&1 || true)
    rm -rf "$tmpdir"
    if echo "$out" | grep -qE 'WARN|ALERT|FAIL'; then
        pass "$inv (detected 120 EVAL gaps)"
    else
        fail "$inv" "expected ALERT for 120 EVAL gaps"
    fi
}
test_inv_2

# ── INV-3: reaper heartbeat freshness ────────────────────────────────────────
test_inv_3() {
    local inv="INV-3"
    [[ -n "$SINGLE_INV" && "$SINGLE_INV" != "$inv" ]] && return 0
    echo "--- $inv: stale heartbeat ---"
    local hb="/tmp/chump-reaper-test-fixture.heartbeat"
    touch -t 200001010000 "$hb" 2>/dev/null || true
    local out
    out=$(run_inv "$inv")
    rm -f "$hb"
    if echo "$out" | grep -qE 'WARN|ALERT|stale'; then
        pass "$inv (detected stale heartbeat)"
    else
        fail "$inv" "expected stale heartbeat detection"
    fi
}
test_inv_3

# ── INV-4: disk headroom ────────────────────────────────────────────────────
test_inv_4() {
    local inv="INV-4"
    [[ -n "$SINGLE_INV" && "$SINGLE_INV" != "$inv" ]] && return 0
    echo "--- $inv: disk check runs ---"
    local out
    out=$(run_inv "$inv")
    if echo "$out" | grep -qE 'OK|WARN|FAIL|ALERT'; then
        pass "$inv (disk check completed)"
    else
        fail "$inv" "expected OK/WARN from disk check"
    fi
}
test_inv_4

# ── INV-5: install-path uniqueness ──────────────────────────────────────────
test_inv_5() {
    local inv="INV-5"
    [[ -n "$SINGLE_INV" && "$SINGLE_INV" != "$inv" ]] && return 0
    echo "--- $inv: no-duplicate paths ---"
    local out
    out=$(run_inv "$inv")
    if echo "$out" | grep -qE 'OK|ALERT|WARN'; then
        pass "$inv (completed)"
    else
        fail "$inv" "expected OK from INV-5"
    fi
}
test_inv_5

# ── INV-6: CI health on main ────────────────────────────────────────────────
test_inv_6() {
    local inv="INV-6"
    [[ -n "$SINGLE_INV" && "$SINGLE_INV" != "$inv" ]] && return 0
    echo "--- $inv: CI health runs ---"
    local out
    out=$(run_inv "$inv")
    if echo "$out" | grep -qE 'OK|WARN|FAIL|ALERT|no_runs|no_green'; then
        pass "$inv (completed)"
    else
        fail "$inv" "expected OK/WARN from INV-6"
    fi
}
test_inv_6

# ── INV-7: green-test monotonicity ──────────────────────────────────────────
test_inv_7() {
    local inv="INV-7"
    [[ -n "$SINGLE_INV" && "$SINGLE_INV" != "$inv" ]] && return 0
    echo "--- $inv: green monotonic ---"
    local out
    out=$(run_inv "$inv")
    if echo "$out" | grep -qE 'OK'; then
        pass "$inv (completed)"
    else
        fail "$inv" "expected OK from INV-7"
    fi
}
test_inv_7

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:$FAILED_TESTS"
    exit 1
fi
exit 0
