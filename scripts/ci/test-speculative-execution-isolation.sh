#!/usr/bin/env bash
# test-speculative-execution-isolation.sh — INFRA-1388 CI gate.
#
# Verifies that speculative_execution tests leave HEAD unchanged in a fresh worktree.
# The test runs cargo test on the speculative_execution module in an isolated branch,
# then verifies that the main branch HEAD is not modified.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# Capture the current HEAD before tests
HEAD_BEFORE=$(git rev-parse HEAD)

# Run speculative_execution tests with sandbox speculation ENABLED to stress-test isolation.
# We run with --test-threads=1 to serialize test execution (tests use #[serial] but this ensures
# no parallel artifact leakage).
export CHUMP_SANDBOX_SPECULATION=1
if ! cargo test --bin chump speculative_execution -- --nocapture --test-threads=1; then
    echo "FAIL: cargo test failed (tests may have crashed)"
    exit 1
fi
unset CHUMP_SANDBOX_SPECULATION

# Verify HEAD is unchanged after tests
HEAD_AFTER=$(git rev-parse HEAD)
if [[ "$HEAD_BEFORE" != "$HEAD_AFTER" ]]; then
    echo "FAIL: HEAD changed during speculative_execution tests!"
    echo "  Before: $HEAD_BEFORE"
    echo "  After:  $HEAD_AFTER"
    echo "  Diff:"
    git log --oneline "$HEAD_BEFORE".."$HEAD_AFTER" || true
    exit 1
fi

# Verify working tree is clean (no untracked or modified files from test leakage)
if [[ -n "$(git status --porcelain)" ]]; then
    echo "FAIL: working tree is dirty after speculative_execution tests!"
    git status --short
    exit 1
fi

# Verify no orphaned worktrees are left behind (INFRA-001b cleanup)
if git worktree list | grep -q ".chump-spec-"; then
    echo "FAIL: orphaned speculative sandbox worktrees remain after tests!"
    git worktree list
    exit 1
fi

echo "PASS: test-speculative-execution-isolation"
echo "  ✓ HEAD unchanged: $HEAD_BEFORE"
echo "  ✓ working tree clean"
echo "  ✓ no orphaned sandbox worktrees"
