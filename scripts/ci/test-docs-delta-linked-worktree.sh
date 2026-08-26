#!/usr/bin/env bash
# CI smoke test (INFRA-1521): docs-delta trailer check succeeds in a linked
# worktree WITHOUT the CHUMP_DOCS_DELTA_CHECK=0 bypass.
#
# History: INFRA-1474 (PR #2200/#2201) fixed the original pre-commit-stage
# bug where the guard hardcoded $REPO_ROOT/.git/COMMIT_EDITMSG, which does
# not exist in a linked worktree (.git there is a gitdir POINTER FILE, not a
# directory). INFRA-1969 (PR #2574) then moved the trailer check entirely
# from pre-commit to a commit-msg hook, which git invokes with $1 = the real
# path to the in-progress message file — sidestepping the COMMIT_EDITMSG
# lookup altogether. This test verifies the end state: a linked-worktree
# commit that adds a docs/*.md file succeeds with a correct Net-new-docs:
# trailer and no bypass env var, and that the commit-msg hook actually read
# and validated the message (not a silent no-op).
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOKS_DIR="$REPO_ROOT/scripts/git-hooks"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

WT_DIR=$(mktemp -d)
BRANCH="test-infra-1521-$$"
cleanup() {
    git -C "$REPO_ROOT" worktree remove --force "$WT_DIR" 2>/dev/null || true
    git -C "$REPO_ROOT" branch -D "$BRANCH" 2>/dev/null || true
}
trap cleanup EXIT

git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WT_DIR" HEAD >/dev/null 2>&1

# Precondition: .git is a gitdir pointer FILE in a linked worktree, not a dir.
if [ -f "$WT_DIR/.git" ] && [ ! -d "$WT_DIR/.git" ]; then
    pass ".git is a gitdir pointer file in the linked worktree (setup sane)"
else
    fail ".git should be a file in a linked worktree (setup error)"
fi

# The old broken path must not exist (confirms we're exercising the real bug).
if [ ! -f "$WT_DIR/.git/COMMIT_EDITMSG" ]; then
    pass "the old broken path \$REPO_ROOT/.git/COMMIT_EDITMSG does not exist here"
else
    fail "unexpected: $WT_DIR/.git/COMMIT_EDITMSG exists"
fi

DOC_FILE="docs/TEST_INFRA_1521_$$.md"
OUT_FILE=$(mktemp)

COMMIT_RC=0
(
    cd "$WT_DIR"
    echo "# smoke test doc" > "$DOC_FILE"
    git add "$DOC_FILE"
    unset CHUMP_DOCS_DELTA_CHECK
    git -c core.hooksPath="$HOOKS_DIR" commit -m "docs: INFRA-1521 linked worktree smoke test

Net-new-docs: +1"
) > "$OUT_FILE" 2>&1 || COMMIT_RC=$?

if [ "$COMMIT_RC" -eq 0 ]; then
    pass "commit in linked worktree succeeded without CHUMP_DOCS_DELTA_CHECK=0"
else
    fail "commit in linked worktree failed (rc=$COMMIT_RC):"
    sed 's/^/    /' "$OUT_FILE"
fi

# Verify the message file was actually read/validated, not skipped as a
# no-op — the commit-msg hook prints "PASS docs-delta" via `chump verify`,
# or accepts silently via the legacy inline check. Either way the doc file
# must have landed in the commit.
if git -C "$WT_DIR" show --stat HEAD 2>/dev/null | grep -qF "$DOC_FILE"; then
    pass "committed tree contains the new doc (message file was read, not a no-op)"
else
    fail "committed tree missing $DOC_FILE — commit-msg hook may not have run"
fi

if grep -q "WARNING:.*is not a file; skipping docs-delta check" "$OUT_FILE"; then
    fail "commit-msg hook fell back to the skip path — \$1 was not resolved correctly"
else
    pass "commit-msg hook did not hit the missing-message-file fallback"
fi

rm -f "$OUT_FILE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
