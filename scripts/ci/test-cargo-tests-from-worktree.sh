#!/usr/bin/env bash
# INFRA-1057: verify cargo tests pass when run from a linked /tmp/ worktree.
# AC-1: 0 failures, 0 hangs within 5-min wall-clock budget.
# AC-4: this script runs on every PR; failure blocks merge.
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
WORKTREE_PATH="$(mktemp -d /tmp/chump-infra-1057-ci-XXXXXX)"
BRANCH="chump/infra-1057-ci-$$"
trap 'git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_PATH" 2>/dev/null; git -C "$REPO_ROOT" branch -D "$BRANCH" 2>/dev/null || true' EXIT

echo "[INFRA-1057] adding temporary worktree at $WORKTREE_PATH"
git -C "$REPO_ROOT" worktree add --quiet "$WORKTREE_PATH" -b "$BRANCH" HEAD

echo "[INFRA-1057] running cargo test from linked worktree (5-min budget)"
cd "$WORKTREE_PATH"
timeout 300 cargo test --bin chump \
  version::tests \
  rescue_tally::tests \
  repo_path::tests \
  -- --test-threads=2 2>&1

echo "[INFRA-1057] PASS: all targeted tests passed from linked worktree"
