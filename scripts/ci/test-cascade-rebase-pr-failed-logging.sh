#!/usr/bin/env bash
# test-cascade-rebase-pr-failed-logging.sh — META-145
#
# Regression test: verifies every early-return failure path inside
# cascade_auto_resolve_pr() in queue-driver.sh emits kind=cascade_rebase_pr_failed
# with a distinguishing `reason`, so per-PR cascade-rebase failures are
# individually auditable in ambient.jsonl (AC #3 of META-145: "the auto-rebase
# mechanism logs its actions and any failures").
#
# Static/grep-based, matching the convention of the sibling cascade tests
# (test-cascade-rebase-on-cargo.sh, test-cascade-rebase-extended-paths.sh) —
# executing the real function requires a live git remote + gh auth, which
# isn't available in CI.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
DRIVER="$REPO_ROOT/scripts/coord/queue-driver.sh"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── 1. Helper function exists ──────────────────────────────────────────────
if grep -q '_cascade_emit_pr_failed()' "$DRIVER"; then
    pass "_cascade_emit_pr_failed helper defined"
else
    fail "_cascade_emit_pr_failed helper missing"
fi

# ── 2. Event kind is emitted with the scanner-anchor comment ──────────────
if grep -q '# scanner-anchor: "kind":"cascade_rebase_pr_failed"' "$DRIVER"; then
    pass "cascade_rebase_pr_failed has scanner-anchor comment"
else
    fail "cascade_rebase_pr_failed missing scanner-anchor comment"
fi

# ── 3. Every documented failure reason has a call site ────────────────────
for reason in \
    branch_resolve_failed \
    worktree_add_failed \
    push_failed_after_clean_rebase \
    rebase_odd_state \
    auto_resolve_script_failed \
    rebase_continue_failed \
    push_failed_after_resolve; do
    if grep -q "_cascade_emit_pr_failed \"$reason\"" "$DRIVER"; then
        pass "reason='$reason' has an emit call site"
    else
        fail "reason='$reason' has NO emit call site — this failure path is silent"
    fi
done

# ── 4. cascade_auto_resolve_pr receives triggered_by so failures carry it ──
if grep -q 'cascade_auto_resolve_pr "\$pr" "\$triggered_by"' "$DRIVER"; then
    pass "cascade_auto_resolve_pr call site passes triggered_by"
else
    fail "cascade_auto_resolve_pr call site does not pass triggered_by"
fi

# ── 5. Event kind is registered so the coverage audit doesn't flag it ─────
ALLOWLIST="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
if grep -q '^cascade_rebase_pr_failed ' "$ALLOWLIST"; then
    pass "cascade_rebase_pr_failed registered in event-registry-reserved.txt"
else
    fail "cascade_rebase_pr_failed NOT registered — event-registry-coverage gate will flag it"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
