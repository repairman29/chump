#!/usr/bin/env bash
# capability-guard-exempt: builds/tests chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-collision-prediction.sh — INFRA-1763
#
# Smoke test for lease-time predictive collision detection (git-diff
# intersection across active leases at claim time).
#
# Verifies:
#   1. docs/design/COLLISION_PREDICTION_SCHEMA.md exists (wire format spec)
#   2. docs/observability/EVENT_REGISTRY.yaml registers kind=collision_predicted
#   3. The Rust unit tests for the feature (git_diff_changed_files,
#      check_git_diff_collision, emit_collision_predicted_event,
#      path_matches_claim_pattern) pass
#
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILS+=("$1"); }

echo "=== INFRA-1763 lease-time predictive collision detection smoke test ==="
echo

# ── Check 1: schema doc exists ────────────────────────────────────────────────
echo "Check 1: collision prediction schema doc exists"
if [[ -f "$REPO_ROOT/docs/design/COLLISION_PREDICTION_SCHEMA.md" ]]; then
    ok "docs/design/COLLISION_PREDICTION_SCHEMA.md exists"
else
    fail "docs/design/COLLISION_PREDICTION_SCHEMA.md missing"
fi

# ── Check 2: registry entry ───────────────────────────────────────────────────
echo
echo "Check 2: collision_predicted registered in EVENT_REGISTRY.yaml"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q '^\s*-\s*kind:\s*collision_predicted' "$REGISTRY"; then
    ok "collision_predicted is a registered kind"
else
    fail "collision_predicted missing from $REGISTRY"
fi

for field in schema_version agents predicted_collision_ts confidence evidence recommended_action; do
    if grep -A 20 '^\s*-\s*kind:\s*collision_predicted' "$REGISTRY" | grep -q "$field"; then
        ok "registry fields_required mentions $field"
    else
        fail "registry entry for collision_predicted missing field $field"
    fi
done

# ── Check 3: unit tests pass ──────────────────────────────────────────────────
echo
echo "Check 3: cargo unit tests for the feature pass"
TEST_NAMES=(
    "path_matches_claim_pattern_exact_and_dir_and_glob"
    "git_diff_changed_files_finds_tracked_and_untracked_edits"
    "git_diff_changed_files_empty_when_no_changes"
    "git_diff_changed_files_empty_on_non_git_dir"
    "check_git_diff_collision_detects_overlap_with_sibling_worktree"
    "check_git_diff_collision_empty_when_no_path_overlap"
    "check_git_diff_collision_skips_self_session"
    "emit_collision_predicted_event_writes_schema_compliant_json"
)

if cargo test --bin chump atomic_claim:: -- --test-threads=1 2>&1 | tee /tmp/infra1763-test-out.txt | tail -40; then
    for t in "${TEST_NAMES[@]}"; do
        if grep -q "test atomic_claim::tests::${t} ... ok" /tmp/infra1763-test-out.txt; then
            ok "cargo test: $t"
        else
            fail "cargo test: $t did not report ok"
        fi
    done
else
    fail "cargo test atomic_claim:: failed (see /tmp/infra1763-test-out.txt)"
fi
rm -f /tmp/infra1763-test-out.txt

# ── Summary ────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
[[ $FAIL -eq 0 ]]
