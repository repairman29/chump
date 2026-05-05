#!/usr/bin/env bash
# INFRA-459 — inverted cost-guard on FLEET_BACKEND=chump-local.
# Default is now claude+haiku. chump-local is blocked unless the operator
# explicitly sets CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1 (cascade bank
# too small for dev workload per operator 2026-05-04).

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dispatch/run-fleet.sh"

# Use a per-test tmux session name to avoid colliding with any live
# fleet on the developer machine. CHUMP_FLEET_NOENV=1 skips the .env
# source so test runs in a clean envelope.
TEST_ENV=(FLEET_SESSION="chump-fleet-test-$$" FLEET_DRY_RUN=1 CHUMP_FLEET_NOENV=1)

# 1. Default (no FLEET_BACKEND set) → claude → no guard hit.
out=$(env "${TEST_ENV[@]}" bash "$SCRIPT" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q "REFUSING"; then
    pass "default backend (claude) starts cleanly"
else
    fail "default should not trigger guard (rc=$rc)"
fi

# 2. FLEET_BACKEND=chump-local without override → REFUSE rc=2.
out=$(env "${TEST_ENV[@]}" FLEET_BACKEND=chump-local bash "$SCRIPT" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 2 ]] && echo "$out" | grep -q "REFUSING to start fleet on backend=chump-local"; then
    pass "FLEET_BACKEND=chump-local refused without explicit override (rc=2)"
else
    fail "FLEET_BACKEND=chump-local should refuse with rc=2 + REFUSING message (rc=$rc, out=$(echo "$out" | head -3))"
fi

# 3. FLEET_BACKEND=chump-local WITH override → allowed.
out=$(env "${TEST_ENV[@]}" FLEET_BACKEND=chump-local CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1 \
        bash "$SCRIPT" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q "REFUSING"; then
    pass "FLEET_BACKEND=chump-local allowed with CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1"
else
    fail "explicit override should allow chump-local (rc=$rc)"
fi

# 4. Refusal message names the override env var (so the operator knows the unblock).
out=$(env "${TEST_ENV[@]}" FLEET_BACKEND=chump-local bash "$SCRIPT" 2>&1 || true)
if echo "$out" | grep -q "CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1"; then
    pass "refusal message names the override env var"
else
    fail "refusal message must tell operator how to unblock"
fi

# 5. FLEET_BACKEND=claude (explicit) → allowed without any override.
out=$(env "${TEST_ENV[@]}" FLEET_BACKEND=claude bash "$SCRIPT" 2>&1) && rc=$? || rc=$?
if [[ $rc -eq 0 ]] && ! echo "$out" | grep -q "REFUSING"; then
    pass "FLEET_BACKEND=claude allowed without override (it is the default)"
else
    fail "FLEET_BACKEND=claude should not be blocked (rc=$rc)"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
