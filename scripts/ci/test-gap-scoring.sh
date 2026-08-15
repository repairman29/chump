#!/usr/bin/env bash
# test-gap-scoring.sh — INFRA-1816
#
# Smoke test for src/gap_scoring.rs::calculate_gap_value_score, vendored from
# repairman29/echeo's Ship Velocity Score (src/matchmaker.rs). Verifies the
# unit tests baked into the module produce a deterministic 0.0..=1.0 score
# from a synthetic gap + routing_outcomes fixture.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "=== INFRA-1816 gap-scoring smoke test ==="
echo

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

if grep -q "pub fn calculate_gap_value_score" src/gap_scoring.rs; then
    ok "calculate_gap_value_score defined in src/gap_scoring.rs"
else
    fail "calculate_gap_value_score missing from src/gap_scoring.rs"
fi

if grep -q "afbe64d6ddea1a89a486015eac1d9584b26d785f" src/gap_scoring.rs; then
    ok "vendoring lineage comment cites repairman29/echeo commit SHA"
else
    fail "vendoring lineage comment missing echeo commit SHA"
fi

if PATH="$HOME/.cargo/bin:$PATH" cargo test --bin chump gap_scoring:: --quiet 2>&1 | tee /tmp/gap-scoring-test-out.txt; then
    ok "cargo test gap_scoring:: passed (full-match clamp, mismatch below-threshold, determinism)"
else
    fail "cargo test gap_scoring:: failed"
    cat /tmp/gap-scoring-test-out.txt
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
