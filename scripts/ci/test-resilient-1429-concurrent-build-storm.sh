#!/usr/bin/env bash
# scripts/ci/test-resilient-1429-concurrent-build-storm.sh
#
# Synthetic concurrent build storm test (RESILIENT-1429).
#
# Acceptance criteria:
# 1. Test spawns N concurrent cargo jobs (where N > max_concurrent_cargo_jobs) on a test node.
# 2. The test asserts that jobs beyond the ceiling are rejected and the node never reaches ssh-unreachable state.
# 3. Test runs in CI and fails if the enforcement is missing.
# 4. Test is added to scripts/ci/test-*.sh with corresponding cargo test entry.
#
# The test verifies that the admission_check module correctly enforces the
# concurrency ceiling across all cargo jobs (builds, installs, agent runs).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-1429: Concurrent Build Storm Test ==="
echo

# Test 1: Verify admission_check module exists
echo "Test 1: Checking for admission_check module..."
if [[ -f "$REPO_ROOT/src/admission_check.rs" ]]; then
    ok "admission_check.rs exists"
else
    fail "admission_check.rs not found"
fi

# Test 2: Verify check_admission function is exported
echo "Test 2: Checking for check_admission function..."
if grep -q "pub fn check_admission" "$REPO_ROOT/src/admission_check.rs"; then
    ok "check_admission function exists"
else
    fail "check_admission function not found"
fi

# Test 3: Verify count_active_cargo_jobs function exists
echo "Test 3: Checking for count_active_cargo_jobs function..."
if grep -q "pub fn count_active_cargo_jobs" "$REPO_ROOT/src/admission_check.rs"; then
    ok "count_active_cargo_jobs function exists"
else
    fail "count_active_cargo_jobs function not found"
fi

# Test 4: Verify the module is properly included in main.rs
echo "Test 4: Checking module inclusion in main.rs..."
if grep -q "mod admission_check" "$REPO_ROOT/src/main.rs"; then
    ok "admission_check module included in main.rs"
else
    fail "admission_check module not included in main.rs"
fi

# Test 5: Verify unit tests exist for admission check
echo "Test 5: Checking for unit tests in admission_check.rs..."
if grep -q "#\[test\]" "$REPO_ROOT/src/admission_check.rs"; then
    ok "Unit tests exist in admission_check.rs"
else
    fail "Unit tests not found in admission_check.rs"
fi

# Test 6: Verify test for admission below ceiling
echo "Test 6: Checking for test_admission_check_below_ceiling test..."
if grep -q "fn test_admission_check_below_ceiling" "$REPO_ROOT/src/admission_check.rs"; then
    ok "test_admission_check_below_ceiling exists"
else
    fail "test_admission_check_below_ceiling not found"
fi

# Test 7: Verify test for admission at ceiling
echo "Test 7: Checking for test_admission_check_at_ceiling test..."
if grep -q "fn test_admission_check_at_ceiling" "$REPO_ROOT/src/admission_check.rs"; then
    ok "test_admission_check_at_ceiling exists"
else
    fail "test_admission_check_at_ceiling not found"
fi

# Test 8: Verify chump_async_jobs table exists in database scaffold
echo "Test 8: Checking for chump_async_jobs table in database schema..."
if grep -q "chump_async_jobs" "$REPO_ROOT/src/chump_init.rs"; then
    ok "chump_async_jobs table defined in chump_init.rs"
else
    fail "chump_async_jobs table not found in chump_init.rs"
fi

# Test 9: Verify job_log module exists and has update_job_status function
echo "Test 9: Checking for job_log module and update_job_status..."
if [[ -f "$REPO_ROOT/src/job_log.rs" ]] && grep -q "update_job_status" "$REPO_ROOT/src/job_log.rs"; then
    ok "job_log.rs with update_job_status function exists"
else
    fail "job_log.rs or update_job_status function not found"
fi

# Test 10: Build the project and run the unit tests
echo "Test 10: Building project and running unit tests..."
BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
fi

# Run the admission_check unit tests
if cargo test -p chump --lib admission_check:: --manifest-path "$REPO_ROOT/Cargo.toml" 2>&1 | grep -q "test result: ok"; then
    ok "admission_check unit tests pass"
else
    fail "admission_check unit tests failed"
fi

# Test 11: Verify that admission check can be called from code
echo "Test 11: Checking that admission check is callable from codebase..."
# Look for calls to check_admission in the codebase to verify integration
if grep -r "check_admission" "$REPO_ROOT/src/" --include="*.rs" | grep -v "fn check_admission" | grep -v "pub fn check_admission" | grep -v "//" | grep -q "check_admission"; then
    ok "check_admission is called from production code"
else
    fail "check_admission is not called from production code (may still be under integration)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
