#!/usr/bin/env bash
# scripts/ci/test-stale-branch-rebase.sh — INFRA-1429

set -uo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/src/paramedic.rs"

echo "=== INFRA-1429 stale-branch auto-rebase tests ==="

for sym in \
    "fn stale_branch_max_age_min" \
    "fn is_stale_by_age" \
    "fn has_do_not_paramedic_label" \
    "fn emit_stale_branch_event" \
    'stale_branch_auto_rebased' \
    "CHUMP_PARAMEDIC_STALE_BRANCH_MAX_AGE_MIN" \
    "do-not-paramedic" \
    "merge fallback"; do
    if grep -q "$sym" "$SRC"; then ok "paramedic.rs contains $sym"; else fail "missing $sym"; fi
done

# updatedAt + labels added to gh pr list JSON query.
if grep -q "number,headRefName,headRefOid,mergeable,mergeStateStatus,updatedAt,labels" "$SRC"; then
    ok "gh pr list query includes updatedAt + labels"
else
    fail "gh pr list query missing updatedAt + labels"
fi

# Unit tests
if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test stale_branch_tests ...]"
    if (cd "$REPO_ROOT" && cargo test --bin chump stale_branch_tests --quiet -- --test-threads=1 2>&1 | tail -10); then
        ok "cargo test stale_branch_tests passed"
    else
        fail "cargo test stale_branch_tests failed"
    fi
fi

# Fixture-based age gate: 31-min-old PR fires; 29-min-old does not.
# Driven entirely by the unit test is_stale_by_age_respects_threshold,
# which is deterministic. Surface as a separate PASS so the AC#5 line
# is visible in the CI output.
if (cd "$REPO_ROOT" && cargo test --bin chump stale_branch_tests::is_stale_by_age_respects_threshold --quiet -- --test-threads=1 2>&1 | grep -q "test result: ok"); then
    ok "AC#5: 31-min-old fires, 29-min-old does not"
else
    fail "AC#5 fixture test missing"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
