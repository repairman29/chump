#!/usr/bin/env bash
# test-prepush-worktree-cd.sh — RESILIENT-009
#
# Tests that the pre-push hook runs cargo test from GIT_WORK_TREE (the linked
# worktree's root) rather than the invoking shell's cwd. This prevents a
# compile error in the main worktree from blocking pushes from linked worktrees.
#
# Tests:
#   1. pre-push hook's cargo test invocation is wrapped in (cd "$REPO_ROOT_T" && ...)
#   2. Verify grep finds the fix pattern in the hook source

set -uo pipefail

PASS=0; FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

echo "=== RESILIENT-009 pre-push worktree-cd tests ==="
echo

# ── 1. Hook uses (cd "$REPO_ROOT_T" && cargo test ...) ───────────────────────
echo "[1. Hook wraps cargo test in subshell cd to REPO_ROOT_T]"
if grep -q 'cd.*REPO_ROOT_T.*cargo test' "$HOOK"; then
    ok "pre-push uses (cd \"\$REPO_ROOT_T\" && cargo test ...)"
else
    fail "pre-push does NOT wrap cargo test with cd to REPO_ROOT_T — linked worktree pushes will test wrong tree"
fi

# ── 2. REPO_ROOT_T is set before the cargo test block ────────────────────────
echo
echo "[2. REPO_ROOT_T assigned from git rev-parse --show-toplevel]"
if grep -q 'REPO_ROOT_T.*git rev-parse --show-toplevel' "$HOOK"; then
    ok "REPO_ROOT_T is derived from git rev-parse --show-toplevel"
else
    fail "REPO_ROOT_T not found in pre-push — cannot verify cd target"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
