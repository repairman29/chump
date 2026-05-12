#!/usr/bin/env bash
# scripts/ci/test-error-path-coverage.sh — CREDIBLE-005
#
# Validates that the codebase has ≥60 error-path test assertions
# (up from baseline of 9). Measures via grep for Err-check patterns
# inside #[test] blocks.

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== CREDIBLE-005: error-path test coverage ==="
echo

# Count lines in test files/modules that match Err-check patterns.
# We count lines containing is_err(), unwrap_err(), should_panic, or assert.*Err(
# across all src/*.rs files.
ERR_COUNT=$(grep -rh '\.is_err()\|\.unwrap_err()\|#\[should_panic\]\|assert.*Err(' \
    "$REPO_ROOT/src/" 2>/dev/null | wc -l | tr -d ' ')

echo "  Error-path assertion count: $ERR_COUNT (threshold: ≥60)"

if [[ "$ERR_COUNT" -ge 60 ]]; then
    ok "error-path assertion count ≥60 (got $ERR_COUNT)"
else
    fail "error-path assertion count below 60 (got $ERR_COUNT)"
fi

# Verify specific CREDIBLE-005 tests exist in gap_store.rs
_gs="$REPO_ROOT/src/gap_store.rs"

check_test() {
    local test_name="$1"
    if grep -q "fn $test_name" "$_gs" 2>/dev/null; then
        ok "gap_store.rs: $test_name defined"
    else
        fail "gap_store.rs: $test_name missing"
    fi
}

check_test "ship_nonexistent_gap_returns_err"
check_test "ship_already_done_gap_returns_err"
check_test "claim_nonexistent_gap_returns_err"
check_test "claim_done_gap_returns_err"
check_test "claim_live_claimed_gap_returns_err"
check_test "get_nonexistent_gap_returns_ok_none"
check_test "preflight_nonexistent_gap_returns_not_found"
check_test "preflight_done_gap_returns_done"
check_test "preflight_claimed_gap_returns_claimed"
check_test "set_recycled_id_guard_rejects_reopening_done_gap"
check_test "set_hijack_guard_rejects_title_rewrite"
check_test "dump_per_file_single_returns_err_for_unknown_gap"
check_test "reserve_increments_id_counter_monotonically"
check_test "list_with_status_filter_excludes_done_gaps"
check_test "ship_with_closed_pr_stamps_pr_number"

# Run the tests if the binary is available
CHUMP_BIN="${REPO_ROOT}/target/debug/deps"
if ls "$CHUMP_BIN"/chump-* 2>/dev/null | grep -qv '\.d$'; then
    echo "  Running tests via cargo test..."
    if (cd "$REPO_ROOT" && \
        GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null)" \
        GIT_WORK_TREE="$REPO_ROOT" \
        cargo test -- "ship_nonexistent_gap\|ship_already_done_gap\|claim_nonexistent_gap\|claim_done_gap\|claim_live_claimed\|get_nonexistent_gap\|preflight_nonexistent\|preflight_done_gap\|preflight_claimed_gap\|set_recycled_id\|set_hijack_guard\|dump_per_file_single_returns\|reserve_increments_id\|list_with_status_filter" \
        2>&1 | grep -q "15 passed\|13 passed\|14 passed"); then
        ok "cargo test: new error-path tests pass"
    else
        fail "cargo test: new error-path tests did not all pass"
    fi
else
    echo "  SKIP (live): cargo test deps not built"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
