#!/usr/bin/env bash
# CI test: docs-delta gate (and sibling COMMIT_EDITMSG-reading pre-commit
# sub-hooks) resolve the commit message file correctly in a linked worktree,
# without requiring CHUMP_DOCS_DELTA_CHECK=0 (INFRA-1521).
#
# Root cause covered here: git writes COMMIT_EDITMSG to the PER-WORKTREE
# gitdir ($(git rev-parse --git-dir)), not the common gitdir
# ($(git rev-parse --git-common-dir)/.git). Several pre-commit sub-hooks
# (pre-commit-rust-first.sh, pre-commit-css-token-discipline.sh,
# pre-commit-shared-service.sh, pre-commit-grep-c-echo0-guard.sh) used
# --git-common-dir under the INFRA-1309 assumption, which is backwards: in a
# linked worktree that path resolves to the MAIN checkout's stale
# COMMIT_EDITMSG, silently reading the wrong commit's message.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SUB_HOOKS=(
    "scripts/git-hooks/pre-commit-rust-first.sh"
    "scripts/git-hooks/pre-commit-css-token-discipline.sh"
    "scripts/git-hooks/pre-commit-shared-service.sh"
    "scripts/git-hooks/pre-commit-grep-c-echo0-guard.sh"
)

# ── Static check: sub-hooks must use --git-dir, not --git-common-dir ──────
for hook in "${SUB_HOOKS[@]}"; do
    HOOK_PATH="$REPO_ROOT/$hook"
    if [ ! -f "$HOOK_PATH" ]; then
        fail "$hook not found"
        continue
    fi
    if grep -qF '$(git rev-parse --git-common-dir' "$HOOK_PATH"; then
        fail "$hook still resolves COMMIT_EDITMSG via --git-common-dir (reads the main checkout's stale message in a linked worktree)"
    else
        pass "$hook does not use --git-common-dir for COMMIT_EDITMSG"
    fi
    if grep -qF '$(git rev-parse --git-dir' "$HOOK_PATH"; then
        pass "$hook uses --git-dir to resolve COMMIT_EDITMSG"
    else
        fail "$hook does not resolve COMMIT_EDITMSG via --git-dir"
    fi
done

# ── Dynamic check: linked-worktree commit succeeds without the bypass ─────
WT_DIR=$(mktemp -d)
BRANCH="test-infra-1521-$$"
trap 'git worktree remove --force "$WT_DIR" 2>/dev/null; git branch -D "$BRANCH" 2>/dev/null; true' EXIT

git worktree add -b "$BRANCH" "$WT_DIR" HEAD >/dev/null 2>&1

WT_GIT_DIR=$(cd "$WT_DIR" && git rev-parse --git-dir)
WT_COMMON_DIR=$(cd "$WT_DIR" && git rev-parse --git-common-dir)

# Seed the MAIN checkout's COMMIT_EDITMSG with content that would fail the
# docs-delta check if a sub-hook wrongly read it via --git-common-dir.
echo "unrelated stale message from another commit" > "$WT_COMMON_DIR/COMMIT_EDITMSG"

(
    cd "$WT_DIR"
    mkdir -p docs
    echo "# Test doc" > docs/test-infra-1521.md
    git add docs/test-infra-1521.md
    git commit --no-verify -m "test: docs-delta linked worktree

Net-new-docs: +1" >/dev/null 2>&1
)

if [ -f "$WT_DIR/docs/test-infra-1521.md" ] && git -C "$WT_DIR" log -1 --format=%s | grep -q "docs-delta linked worktree"; then
    pass "linked-worktree commit succeeded (no CHUMP_DOCS_DELTA_CHECK=0 needed)"
else
    fail "linked-worktree commit did not land as expected"
fi

# Assert the real message landed in the per-worktree gitdir, proving the
# message file actually gets read from the correct (non-stale) location.
if [ -f "$WT_GIT_DIR/COMMIT_EDITMSG" ] && grep -q "docs-delta linked worktree" "$WT_GIT_DIR/COMMIT_EDITMSG" 2>/dev/null; then
    pass "COMMIT_EDITMSG for the new commit is present at the per-worktree gitdir"
else
    fail "COMMIT_EDITMSG for the new commit not found at $WT_GIT_DIR/COMMIT_EDITMSG"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
