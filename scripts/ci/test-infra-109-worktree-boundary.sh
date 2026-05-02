#!/usr/bin/env bash
# test-infra-109-worktree-boundary.sh — INFRA-109 regression test.
#
# Verifies that the 5 core coordination scripts resolve LOCK_DIR via the
# MAIN-REPO path (not the linked worktree) when invoked from inside a
# linked worktree. Without the fix, leases written from a worktree go
# to that worktree's local `.chump-locks/`, invisible to siblings.
#
# Pattern: spin up a temp git repo, add a linked worktree, run each
# script from inside the worktree with CHUMP_LOCK_DIR unset, and check
# that LOCK_DIR resolved to <main>/​.chump-locks (not <worktree>/.chump-locks).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/repo-paths.sh"

if [[ ! -f "$LIB" ]]; then
    echo "[FAIL] scripts/lib/repo-paths.sh not found at $LIB"
    exit 1
fi

# ── Setup: temp main repo + temp linked worktree ──────────────────────────────
TMP="$(cd "$(mktemp -d)" && pwd -P)"  # canonicalize to match git's resolution
trap 'rm -rf "$TMP"' EXIT

MAIN="$TMP/main"
WT="$TMP/wt"

mkdir -p "$MAIN"
cd "$MAIN"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"
echo "init" > README.md
git add README.md
git commit -qm "init"
mkdir -p scripts/lib
cp "$LIB" scripts/lib/repo-paths.sh
git add scripts/lib/repo-paths.sh
git commit -qm "lib"

git worktree add -q -b wt-branch "$WT" >/dev/null

# ── Test 1: from MAIN repo, MAIN_REPO == MAIN, LOCK_DIR == MAIN/.chump-locks ─
cd "$MAIN"
unset CHUMP_LOCK_DIR
# shellcheck source=/dev/null
source scripts/lib/repo-paths.sh
[[ "$MAIN_REPO" == "$MAIN" ]] || { echo "[FAIL] from MAIN: MAIN_REPO=$MAIN_REPO expected $MAIN"; exit 1; }
[[ "$LOCK_DIR" == "$MAIN/.chump-locks" ]] || { echo "[FAIL] from MAIN: LOCK_DIR=$LOCK_DIR expected $MAIN/.chump-locks"; exit 1; }
echo "[PASS] from main repo: LOCK_DIR=$LOCK_DIR"

# ── Test 2: from WORKTREE, MAIN_REPO STILL == MAIN, LOCK_DIR STILL == MAIN/.chump-locks ─
cd "$WT"
unset MAIN_REPO LOCK_DIR REPO_ROOT
# shellcheck source=/dev/null
source "$WT/scripts/lib/repo-paths.sh"
# The worktree's own toplevel is $WT, but MAIN_REPO must resolve to $MAIN.
[[ "$REPO_ROOT" == "$WT" ]] || { echo "[FAIL] from WT: REPO_ROOT=$REPO_ROOT expected $WT"; exit 1; }
# This is the key INFRA-109 invariant:
if [[ "$MAIN_REPO" != "$MAIN" ]]; then
    echo "[FAIL] INFRA-109 regression: from worktree MAIN_REPO=$MAIN_REPO expected $MAIN"
    exit 1
fi
if [[ "$LOCK_DIR" != "$MAIN/.chump-locks" ]]; then
    echo "[FAIL] INFRA-109 regression: from worktree LOCK_DIR=$LOCK_DIR expected $MAIN/.chump-locks (worktree-local would be $WT/.chump-locks)"
    exit 1
fi
echo "[PASS] from linked worktree: LOCK_DIR=$LOCK_DIR (correctly resolves to main repo)"

# ── Test 3: CHUMP_LOCK_DIR override still works ────────────────────────────────
unset MAIN_REPO LOCK_DIR REPO_ROOT
export CHUMP_LOCK_DIR="$TMP/override"
# shellcheck source=/dev/null
source "$WT/scripts/lib/repo-paths.sh"
if [[ "$LOCK_DIR" != "$TMP/override" ]]; then
    echo "[FAIL] CHUMP_LOCK_DIR override not honored: LOCK_DIR=$LOCK_DIR"
    exit 1
fi
unset CHUMP_LOCK_DIR
echo "[PASS] CHUMP_LOCK_DIR override honored"

echo ""
echo "[OK] all 3 INFRA-109 worktree-boundary checks passed"
