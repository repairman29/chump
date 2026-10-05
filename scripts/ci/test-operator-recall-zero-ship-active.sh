#!/usr/bin/env bash
# scripts/ci/test-operator-recall-zero-ship-active.sh — RESILIENT-575
#
# Verifies the ZERO_SHIP_ACTIVE condition in scripts/dispatch/operator-recall.sh:
# workers actively cycling (worker_exit events present) but zero gap_shipped
# events in the same window must page. Precedent: 2026-09-01, the sub backend
# quietly failed rc=1 every cycle for 9h — workers looked "active" the whole
# time (worker_exit kept emitting) while nothing shipped, and no existing halt
# condition covers "busy but fruitless" (they all key off idle/dead workers).
#
#   1. Few cycles, no ships           → no ZERO_SHIP_ACTIVE (not enough signal)
#   2. Many cycles, ships present     → no ZERO_SHIP_ACTIVE (fleet is working)
#   3. Many cycles, zero ships        → ZERO_SHIP_ACTIVE recall
#   4. Non-check-only emits the event to ambient.jsonl
#
# All tests use a temporary ambient log so they never touch the real
# .chump-locks/ambient.jsonl.
#
# Exit 0 = all pass. Exit 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECALL="$REPO_ROOT/scripts/dispatch/operator-recall.sh"

PASS=0
FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT
FAKE_AMBIENT="$FAKE_HOME/ambient.jsonl"

# Keep every OTHER operator-recall condition from tripping.
export CHUMP_ZERO_SHIP_WINDOW_SECS=3600
export CHUMP_ZERO_SHIP_MIN_CYCLES=3
export CHUMP_AUTONOMY_HALT_MIN_SECS=999999999
export CHUMP_QUEUE_STARVE_SECS=999999999
export CHUMP_RUNNER_GHOST_ONLINE_DETECT=0
export REPO_ROOT

_run() {
    HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" REPO_ROOT="$REPO_ROOT" \
        bash "$RECALL" --check-only
}

_emit() {
    # $1=kind $2=age_secs_ago
    local kind="$1" age="$2"
    local epoch; epoch=$(( $(date +%s) - age ))
    local ts; ts="$(python3 -c "
import sys
from datetime import datetime, timezone
print(datetime.fromtimestamp(int(sys.argv[1]), tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$epoch")"
    printf '{"ts":"%s","kind":"%s","agent_id":"test"}\n' "$ts" "$kind" >> "$FAKE_AMBIENT"
}

# ── Test 1: few cycles, no ships → no recall (not enough signal yet) ────────
> "$FAKE_AMBIENT"
_emit worker_exit 60
_out="$(_run 2>&1)"; _rc=$?
if echo "$_out" | grep -q "ZERO_SHIP_ACTIVE"; then
    fail "Test 1: single cycle incorrectly triggered ZERO_SHIP_ACTIVE: $_out"
else
    ok "Test 1: single cycle (below min_cycles) did not trigger ZERO_SHIP_ACTIVE (rc=$_rc)"
fi

# ── Test 2: many cycles, ships present → no recall (fleet is working) ───────
> "$FAKE_AMBIENT"
for i in 1 2 3 4 5; do _emit worker_exit 60; done
_emit gap_shipped 120
_out="$(_run 2>&1)"; _rc=$?
if echo "$_out" | grep -q "ZERO_SHIP_ACTIVE"; then
    fail "Test 2: cycles + ships incorrectly triggered ZERO_SHIP_ACTIVE: $_out"
else
    ok "Test 2: cycles + ships present did not trigger ZERO_SHIP_ACTIVE"
fi

# ── Test 3: many cycles, zero ships → ZERO_SHIP_ACTIVE recall ───────────────
> "$FAKE_AMBIENT"
for i in 1 2 3 4 5; do _emit worker_exit 60; done
_out="$(_run 2>&1)"; _rc=$?
if echo "$_out" | grep -q "HALT condition=ZERO_SHIP_ACTIVE"; then
    ok "Test 3: cycles active + 0 ships triggered ZERO_SHIP_ACTIVE"
else
    fail "Test 3: cycles active + 0 ships did NOT trigger ZERO_SHIP_ACTIVE: $_out"
fi
if [[ "$_rc" -eq 1 ]]; then
    ok "Test 3: --check-only exited 1 on ZERO_SHIP_ACTIVE"
else
    fail "Test 3: --check-only expected exit 1, got $_rc"
fi

# ── Test 4: non-check-only mode emits kind=operator_recall,condition=ZERO_SHIP_ACTIVE ──
> "$FAKE_AMBIENT"
for i in 1 2 3 4 5; do _emit worker_exit 60; done
HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" REPO_ROOT="$REPO_ROOT" \
    bash "$RECALL" >/dev/null 2>&1 || true
if grep -q '"kind":"operator_recall"' "$FAKE_AMBIENT" && grep -q '"condition":"ZERO_SHIP_ACTIVE"' "$FAKE_AMBIENT"; then
    ok "Test 4: non-check-only run emitted operator_recall/ZERO_SHIP_ACTIVE to ambient"
else
    fail "Test 4: no operator_recall/ZERO_SHIP_ACTIVE event found in ambient: $(cat "$FAKE_AMBIENT")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
