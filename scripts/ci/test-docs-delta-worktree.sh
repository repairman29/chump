#!/usr/bin/env bash
# CI test: docs-delta trailer check correctly reads the commit message in
# linked worktrees.
#
# Covers INFRA-1474: $REPO_ROOT/.git/COMMIT_EDITMSG doesn't exist in a linked
# worktree because .git is a gitdir pointer file, not a directory.
#
# Superseded architecture (INFRA-1969, PR #2574): the trailer check no
# longer lives at pre-commit stage — it moved to a commit-msg hook, which
# git invokes with $1 = the real path to the message file, sidestepping the
# COMMIT_EDITMSG lookup entirely. This test was written against the old
# pre-commit-stage implementation and went stale (and unnoticed, since it
# was never wired into ci.yml) when that move landed. Updated under
# INFRA-1521 to assert against current reality; see
# scripts/ci/test-docs-delta-linked-worktree.sh for the full end-to-end
# smoke test added alongside this fix.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOK="$REPO_ROOT/scripts/git-hooks/commit-msg"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Setup: create a temp linked worktree ────────────────────────────────────
WT_DIR=$(mktemp -d)
BRANCH="test-infra-1474-$$"
trap 'git worktree remove --force "$WT_DIR" 2>/dev/null; git branch -D "$BRANCH" 2>/dev/null; true' EXIT

git worktree add -b "$BRANCH" "$WT_DIR" HEAD >/dev/null 2>&1

# Verify the linked worktree has a file .git, not a directory (the precondition)
if [ -f "$WT_DIR/.git" ] && [ ! -d "$WT_DIR/.git" ]; then
    pass ".git is a file in linked worktree (gitdir pointer)"
else
    fail ".git should be a file in linked worktree (setup error)"
fi

# Verify that the old broken path doesn't exist in the linked worktree
BROKEN_PATH="$WT_DIR/.git/COMMIT_EDITMSG"
if [ ! -f "$BROKEN_PATH" ]; then
    pass "old broken path \$REPO_ROOT/.git/COMMIT_EDITMSG does not exist in linked worktree"
else
    fail "old broken path $BROKEN_PATH unexpectedly exists"
fi

# Verify that git rev-parse --git-dir returns a real directory in the linked worktree
WT_GIT_DIR=$(cd "$WT_DIR" && git rev-parse --git-dir)
if [ -d "$WT_GIT_DIR" ]; then
    pass "git rev-parse --git-dir ($WT_GIT_DIR) is a real directory"
else
    fail "git rev-parse --git-dir ($WT_GIT_DIR) is not a directory"
fi

# ── Verify the commit-msg hook reads the message via $1, not a
#    hardcoded/derived COMMIT_EDITMSG path ─────────────────────────────────
if grep -qF '\${1:?commit-msg hook expects \$1' "$HOOK" || grep -qF 'MSG_FILE="${1:?' "$HOOK"; then
    pass "commit-msg hook reads the message via \$1 (git-supplied real path)"
else
    fail "commit-msg hook no longer reads the message via \$1 (regression)"
fi

if grep -qF '$REPO_ROOT/.git/COMMIT_EDITMSG' "$HOOK"; then
    fail "commit-msg hook contains the broken \$REPO_ROOT/.git/COMMIT_EDITMSG path"
else
    pass "commit-msg hook does not contain the broken \$REPO_ROOT/.git/COMMIT_EDITMSG path"
fi

# ── End-to-end: a real `git commit` in the linked worktree, driving the
#    commit-msg hook exactly as git would ──────────────────────────────────
DOC_FILE="docs/TEST_INFRA_1474_$$.md"
COMMIT_RC=0
(
    cd "$WT_DIR"
    echo "# smoke test doc" > "$DOC_FILE"
    git add "$DOC_FILE"
    unset CHUMP_DOCS_DELTA_CHECK
    git -c core.hooksPath="$REPO_ROOT/scripts/git-hooks" commit -m "docs: INFRA-1474 worktree regression test

Net-new-docs: +1"
) >/tmp/test-docs-delta-worktree.$$.out 2>&1 || COMMIT_RC=$?

if [ "$COMMIT_RC" -eq 0 ]; then
    pass "real git commit in linked worktree succeeded without CHUMP_DOCS_DELTA_CHECK=0"
else
    fail "real git commit in linked worktree failed (rc=$COMMIT_RC):"
    sed 's/^/    /' /tmp/test-docs-delta-worktree.$$.out
fi
rm -f /tmp/test-docs-delta-worktree.$$.out

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
