#!/usr/bin/env bash
# INFRA-425 — verify the pre-commit cargo-check guard short-circuits
# when no .rs files are staged. Regression pin for the INFRA-257 fix
# (see scripts/git-hooks/pre-commit:1522-1527 for the current gate).
#
# Strategy: static check on the hook — the cargo-block must be wrapped
# in `if [ -n "$staged_rust" ]; then` so doc-only / yaml-only commits
# don't pay the 30-90s cargo check tax.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"

[[ -f "$HOOK" ]] || { fail "pre-commit hook missing"; exit 1; }
pass "pre-commit hook present"

# 1. The staged_rust capture exists.
grep -q 'staged_rust=$(git diff --cached --name-only.*\.rs' "$HOOK" \
    && pass "staged_rust capture present" \
    || fail "staged_rust capture missing"

# 2. The cargo block is wrapped in `if [ -n "$staged_rust" ]; then`.
#    Match the line that gates the rust-only blocks.
if grep -q 'if \[ -n "\$staged_rust" \]; then' "$HOOK"; then
    pass "cargo block gated on staged .rs files"
else
    fail "cargo block must be gated on staged_rust"
fi

# 3. The cargo check command is INSIDE that gate (line number check).
GATE_LINE=$(grep -n 'if \[ -n "\$staged_rust" \]; then' "$HOOK" | head -1 | cut -d: -f1)
CHECK_LINE=$(grep -n 'cargo check --bin chump' "$HOOK" | head -1 | cut -d: -f1)
if [[ -n "$GATE_LINE" && -n "$CHECK_LINE" && "$CHECK_LINE" -gt "$GATE_LINE" ]]; then
    pass "cargo check (line $CHECK_LINE) is below the staged_rust gate (line $GATE_LINE)"
else
    fail "cargo check must sit inside the staged_rust gate"
fi

# 4. Behavioral check: invoke the hook in a fixture worktree where only
#    a doc file is staged. The cargo block should not run.
#    (We can't fully exec the hook without a real commit context, but we
#    can grep the hook output for cargo-check noise.)
fixture=$(mktemp -d)
trap "rm -rf $fixture" EXIT
cd "$fixture"
git init --quiet
git config user.email "test@test"
git config user.name "test"
mkdir -p docs
echo "test doc" > docs/notes.md
git add docs/notes.md
# Stub minimal env so the hook doesn't choke on missing optional pieces.
cp "$HOOK" .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
# Run the hook directly with a dry STDIN; it should NOT run cargo check.
# Many guards will exit 0 silently because their fixtures don't trigger.
out=$(CHUMP_LEASE_CHECK=0 CHUMP_DOCS_DELTA_CHECK=0 CHUMP_GAPS_LOCK=0 \
        CHUMP_PREREG_CHECK=0 CHUMP_CROSS_JUDGE_CHECK=0 \
        bash .git/hooks/pre-commit 2>&1 || true)
if echo "$out" | grep -q "cargo check"; then
    fail "doc-only commit triggered cargo check (should skip)"
else
    pass "doc-only commit skipped cargo check"
fi
cd "$REPO_ROOT"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
