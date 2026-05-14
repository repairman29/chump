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
    "$REPO_ROOT/src/" "$REPO_ROOT/crates/" 2>/dev/null | wc -l | tr -d ' ')

echo "  Error-path assertion count: $ERR_COUNT (threshold: ≥60)"

if [[ "$ERR_COUNT" -ge 60 ]]; then
    ok "error-path assertion count ≥60 (got $ERR_COUNT)"
else
    fail "error-path assertion count below 60 (got $ERR_COUNT)"
fi

# Verify specific CREDIBLE-005 tests exist in gap_store.rs
# INFRA-693: gap_store.rs moved to crates/chump-gap-store/src/lib.rs.
if [[ -f "$REPO_ROOT/crates/chump-gap-store/src/lib.rs" ]]; then
    _gs="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"
else
    _gs="$REPO_ROOT/src/gap_store.rs"
fi

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
    # cargo test takes filter args as separate positional strings (substring OR-match),
    # not a single regex. Run gap_store unit tests and require zero failures.
    # Drop --quiet — cargo test --quiet suppresses the "test result: ok. N
    # passed" summary line we need to parse. Use full output. We need the
    # exit code AND the count of passed tests.
    # INFRA-693: gap_store extracted to crates/chump-gap-store. Use -p flag
    # to target the library crate directly; --bin chump misses library tests.
    _cargo_pkg_flag="-p chump-gap-store"
    if [[ ! -f "$REPO_ROOT/crates/chump-gap-store/Cargo.toml" ]]; then
        _cargo_pkg_flag="--bin chump"
    fi
    test_out=$(cd "$REPO_ROOT" && \
        GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null)" \
        GIT_WORK_TREE="$REPO_ROOT" \
        cargo test $_cargo_pkg_flag 2>&1)
    test_rc=$?
    passed=$(echo "$test_out" | awk -F'[ .;]+' '/test result: ok\./{for(i=1;i<=NF;i++) if($i=="passed"){print $(i-1)}}' | awk '{s+=$1} END{print s+0}')
    failed=$(echo "$test_out" | awk -F'[ .;]+' '/test result/{for(i=1;i<=NF;i++) if($i=="failed"){print $(i-1)}}' | awk '{s+=$1} END{print s+0}')
    if [[ "$test_rc" -eq 0 ]] && [[ "$failed" -eq 0 ]] && [[ "$passed" -ge 15 ]]; then
        ok "cargo test: gap_store error-path tests pass ($passed passed)"
    else
        fail "cargo test: gap_store error-path tests did not all pass (rc=$test_rc passed=$passed failed=$failed)"
        echo "  [diag] last 40 lines of cargo test output:" >&2
        echo "$test_out" | tail -40 >&2
    fi
else
    echo "  SKIP (live): cargo test deps not built"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
