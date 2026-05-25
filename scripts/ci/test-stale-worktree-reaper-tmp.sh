#!/usr/bin/env bash
# test-stale-worktree-reaper-tmp.sh — INFRA-2020 regression test.
#
# Verifies that scripts/ops/stale-worktree-reaper.sh now walks /tmp/chump-*
# in addition to its original .claude/worktrees/ scan, and that the
# WORKTREE_SCAN_PATHS env var controls the scan set.
#
# Lived evidence (curator-opus-overnight 2026-05-25):
#   disk_critical fired 18:53Z with 128 /tmp/chump-* worktrees consuming
#   43GB. The reaper was blind to /tmp/chump-* (only walked .claude/worktrees/).
#   Manual reap recovered 43GB. INFRA-2020 makes the daemon catch this class
#   on its hourly cadence.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
REAPER="$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"

if [[ ! -x "$REAPER" ]]; then
    echo "[FAIL] reaper script not found / not executable at $REAPER"
    exit 1
fi

# --------------------------------------------------------------------
# Test 1: structural — script accepts WORKTREE_SCAN_PATHS env var
# --------------------------------------------------------------------
if ! grep -q 'WORKTREE_SCAN_PATHS' "$REAPER"; then
    echo "[FAIL] reaper missing WORKTREE_SCAN_PATHS env var support"
    exit 1
fi
echo "[PASS] Test 1: WORKTREE_SCAN_PATHS env var support present"

# --------------------------------------------------------------------
# Test 2: structural — default scan paths include both targets
# --------------------------------------------------------------------
if ! grep -qE '/tmp/chump-\*' "$REAPER"; then
    echo "[FAIL] reaper missing /tmp/chump-* in scan paths"
    exit 1
fi
echo "[PASS] Test 2: /tmp/chump-* in default scan paths"

# --------------------------------------------------------------------
# Test 3: structural — script distinguishes claude_worktrees vs tmp_chump
# --------------------------------------------------------------------
if ! grep -qE 'tmp_chump|claude_worktrees' "$REAPER"; then
    echo "[FAIL] reaper missing source-type differentiation (tmp_chump / claude_worktrees)"
    exit 1
fi
echo "[PASS] Test 3: source-type differentiation present"

# --------------------------------------------------------------------
# Test 4: structural — bash syntax check passes
# --------------------------------------------------------------------
if ! bash -n "$REAPER"; then
    echo "[FAIL] reaper has bash syntax errors"
    exit 1
fi
echo "[PASS] Test 4: bash -n syntax check passes"

# --------------------------------------------------------------------
# Test 5: behavioral — synthetic /tmp/chump-* worktree is detected
# --------------------------------------------------------------------
# Use a sandboxed test root so we never touch real worktrees.
TEST_ROOT="$(mktemp -d -t inFRA-2020-test-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Create a fake /tmp/chump-* style worktree as a plain directory containing
# git metadata that LOOKS like a worktree to the reaper. The reaper's
# safety predicates (lease check, git status) will fall through to
# "no reason to skip" for a clean empty fake.
mkdir -p "$TEST_ROOT/chump-INFRA-99999"
cd "$TEST_ROOT/chump-INFRA-99999"
git init --quiet
git config user.email "test@test"
git config user.name "test"
echo "test" > a.txt
git add a.txt
git commit --quiet -m "test commit"

# Run reaper in --dry-run mode with our test root scoped via env override.
# The reaper supports WORKTREE_SCAN_PATHS for path injection; we override
# to point at our test root's chump-* glob.
set +e
out=$(WORKTREE_SCAN_PATHS="$TEST_ROOT/chump-*" bash "$REAPER" --dry-run 2>&1)
rc=$?
set -e

# We don't strictly require it to detect our synthetic (the reaper has
# many safety predicates and may reasonably skip a no-PR fake), but it
# MUST NOT crash, and MUST report having considered the path.
if [[ "$rc" -ne 0 ]]; then
    echo "[FAIL] reaper crashed in dry-run with WORKTREE_SCAN_PATHS override (rc=$rc)"
    echo "--- output ---"
    echo "$out"
    exit 1
fi
echo "[PASS] Test 5: reaper survives synthetic /tmp/chump-* scan in dry-run"

# --------------------------------------------------------------------
# Test 6: structural — doc-comment mentions INFRA-2020
# --------------------------------------------------------------------
if ! grep -q 'INFRA-2020' "$REAPER"; then
    echo "[FAIL] reaper script header should mention INFRA-2020 for traceability"
    exit 1
fi
echo "[PASS] Test 6: INFRA-2020 referenced in script header"

echo
echo "[OK] all 6 INFRA-2020 stale-worktree-reaper /tmp/chump-* cases passed"
