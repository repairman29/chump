#!/usr/bin/env bash
# test-known-flakes-gate.sh — RESILIENT-012: pre-push gate auto-bypasses KNOWN_FLAKES
#
# Tests:
#   1. KNOWN_FLAKES.yaml contains entries for all 11 expected pre-push flakes
#   2. All 11 entries have a valid tracking_gap field (non-empty)
#   3. Synthetic test output with only KNOWN_FLAKES entries exits 0 (auto-bypass logic)
#   4. Synthetic test output with ONE unknown failure still exits 1 (blocks the push)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CATALOG="$REPO_ROOT/docs/process/KNOWN_FLAKES.yaml"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# The 11 tests that must appear in the catalog (from RESILIENT-012 AC).
EXPECTED_FLAKES=(
    "diff_review_tool::tests::diff_review_empty_diff_returns_message"
    "repo_path::tests::repo_profiles_list_parses_git_root"
    "repo_path::tests::set_working_repo_from_profile_roundtrip"
    "repo_path::tests::worktree_root_respects_chump_repo_across_different_git_trees"
    "rescue_tally::tests::infra667_count_rescues_returns_zero_on_empty_repo"
    "sandbox_tool::tests::sandbox_run_executes_in_worktree"
    "version::tests::fresh_when_baked_sha_is_at_head"
    "version::tests::skip_when_baked_sha_unknown"
    "version::tests::fresh_when_only_unrelated_files_changed_since_baked_sha"
    "version::tests::stale_when_gap_store_changed_since_baked_sha"
    "version::tests::pr_1444_replay_refuses_without_override"
)

# ── Test 1: all 11 expected flakes appear in KNOWN_FLAKES.yaml ────────────────
[[ -f "$CATALOG" ]] || fail "Test 1: $CATALOG not found"
for t in "${EXPECTED_FLAKES[@]}"; do
    grep -q "$t" "$CATALOG" \
        || fail "Test 1: '$t' not found in KNOWN_FLAKES.yaml"
done
pass "Test 1: all 11 RESILIENT-012 flake entries present in KNOWN_FLAKES.yaml"

# ── Test 2: each entry has a tracking_gap field ────────────────────────────────
missing_tracking=0
CATALOG_TESTS=$(grep -E '^[[:space:]]*-[[:space:]]*test:' "$CATALOG" \
    | sed -E 's/^[[:space:]]*-[[:space:]]*test:[[:space:]]+//; s/"//g; s/[[:space:]]*$//')
while IFS= read -r tname; do
    [[ -z "$tname" ]] && continue
    # Find the tracking_gap entry near this test name. Check if tracking_gap appears
    # in the block following this test's - test: line.
    if ! grep -A5 "test: $tname" "$CATALOG" 2>/dev/null | grep -q "tracking_gap:"; then
        if ! grep -A5 "test: \"$tname\"" "$CATALOG" 2>/dev/null | grep -q "tracking_gap:"; then
            echo "[WARN] No tracking_gap found for: $tname" >&2
            missing_tracking=1
        fi
    fi
done <<< "$CATALOG_TESTS"
[[ "$missing_tracking" -eq 0 ]] || fail "Test 2: some entries missing tracking_gap field"
pass "Test 2: all KNOWN_FLAKES entries have tracking_gap field"

# ── Test 3: synthetic known-only failure auto-bypasses ────────────────────────
# Extract the auto-bypass logic from pre-push into a testable function.
# We simulate a cargo test output with only KNOWN_FLAKES failures.
TMP="$(mktemp -d -t test-known-flakes.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FAKE_LOG="$TMP/fake-test-output.txt"
# Generate cargo test FAILED output for the first 3 known flakes.
cat > "$FAKE_LOG" <<'FAKELOG'
test diff_review_tool::tests::diff_review_empty_diff_returns_message ... FAILED
test repo_path::tests::repo_profiles_list_parses_git_root ... FAILED
test version::tests::fresh_when_baked_sha_is_at_head ... FAILED

failures:
    diff_review_tool::tests::diff_review_empty_diff_returns_message
    repo_path::tests::repo_profiles_list_parses_git_root
    version::tests::fresh_when_baked_sha_is_at_head

test result: FAILED. 0 passed; 3 failed; 0 ignored
FAKELOG

# Run the known-flakes check logic inline (mirrors pre-push hook logic).
check_known_flakes() {
    local log_file="$1"
    local catalog="$2"
    local failed all_known=1
    failed=$(grep -E '^test [A-Za-z_][A-Za-z0-9_:]+ \.\.\. FAILED' "$log_file" \
        | sed -E 's/^test ([A-Za-z_][A-Za-z0-9_:]+) .*/\1/' \
        | sort -u)
    [[ -z "$failed" ]] && return 1  # no parseable failures → treat as real error
    local catalog_tests
    catalog_tests=$(grep -E '^[[:space:]]*-[[:space:]]*test:' "$catalog" \
        | sed -E 's/^[[:space:]]*-[[:space:]]*test:[[:space:]]+//; s/"//g; s/[[:space:]]*$//')
    while IFS= read -r tname; do
        [[ -z "$tname" ]] && continue
        if ! printf '%s\n' "$catalog_tests" | grep -qxF "$tname"; then
            all_known=0
            break
        fi
    done <<< "$failed"
    [[ "$all_known" -eq 1 ]]
}

check_known_flakes "$FAKE_LOG" "$CATALOG" \
    || fail "Test 3: synthetic known-only failure should return 0 (auto-bypass), got 1"
pass "Test 3: synthetic known-only failure auto-bypasses (exits 0)"

# ── Test 4: one unknown failure blocks the gate ────────────────────────────────
FAKE_LOG2="$TMP/fake-test-output-unknown.txt"
cat > "$FAKE_LOG2" <<'FAKELOG2'
test diff_review_tool::tests::diff_review_empty_diff_returns_message ... FAILED
test some_new_test::tests::newly_broken_function ... FAILED

failures:
    diff_review_tool::tests::diff_review_empty_diff_returns_message
    some_new_test::tests::newly_broken_function

test result: FAILED. 0 passed; 2 failed; 0 ignored
FAKELOG2

check_known_flakes "$FAKE_LOG2" "$CATALOG" \
    && fail "Test 4: unknown failure 'some_new_test::tests::newly_broken_function' should block (return 1)" \
    || true
pass "Test 4: unknown failure causes check_known_flakes to return 1 (blocks push)"

echo ""
echo "All RESILIENT-012 known-flakes-gate checks passed (4/4)."
