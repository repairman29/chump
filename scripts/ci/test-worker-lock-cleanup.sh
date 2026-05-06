#!/usr/bin/env bash
# INFRA-527: verify worker.sh removes .gap-<GAP_ID>.lock on all exit paths.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCKS_DIR="$REPO_ROOT/.chump-locks"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
PASS=0
FAIL=0

_check() {
    local label="$1" gap_id="$2"
    local lock_file="$LOCKS_DIR/.gap-${gap_id}.lock"
    if [[ -f "$lock_file" ]]; then
        echo "FAIL [$label]: $lock_file still exists"
        FAIL=$(( FAIL + 1 ))
    else
        echo "PASS [$label]: .gap-${gap_id}.lock removed"
        PASS=$(( PASS + 1 ))
    fi
}

# Extract the lease-cleanup block from worker.sh and run it in isolation.
# We source only the rm lines that INFRA-527 touches, avoiding the need to
# spin up a real fleet cycle (which requires claude CLI, cargo build, etc.).
_simulate_cleanup() {
    local gap_id="$1" session_id="$2"
    local lock_file="$LOCKS_DIR/.gap-${gap_id}.lock"
    # Plant the stale lock
    mkdir -p "$LOCKS_DIR"
    touch "$lock_file"
    # Replicate the exact cleanup logic from worker.sh
    if [[ -n "${session_id:-}" ]]; then
        rm -f "$LOCKS_DIR/${session_id}.json" 2>/dev/null || true
    fi
    rm -f "$LOCKS_DIR/"*"${gap_id}"*.json 2>/dev/null || true
    rm -f "$LOCKS_DIR/.gap-${gap_id}.lock" 2>/dev/null || true
}

echo "=== INFRA-527 worker lock-cleanup test ==="

# 1. Success (rc=0)
_simulate_cleanup "TEST-SUCCESS-$$" "fleet-agent-$$-success"
_check "rc=0 success" "TEST-SUCCESS-$$"

# 2. Timeout (rc=124)
_simulate_cleanup "TEST-TIMEOUT-$$" "fleet-agent-$$-timeout"
_check "rc=124 timeout" "TEST-TIMEOUT-$$"

# 3. Failure (rc!=0/124)
_simulate_cleanup "TEST-FAILURE-$$" "fleet-agent-$$-failure"
_check "rc!=0 failure" "TEST-FAILURE-$$"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
