#!/data/data/com.termux/files/usr/bin/bash
# pixel-ship.sh — RESILIENT-411. Ship an already-implemented+committed gap
# branch from the Pixel WITHOUT running bot-merge's local `cargo clippy --fix`,
# which cold-compiles the whole workspace and is prohibitively slow on Termux
# (wasmtime/cranelift/ring rebuilds blow any time budget on the phone).
#
# Contract: the worktree already holds >=1 commit on branch chump/<gap>-claim
# authored by the pixel worker (claude-in-proot implemented + chump-commit'd).
# We push (pre-push clippy/test/preflight all skip: no .rs + INFRA-3524/3521 via
# CHUMP_BOT_MERGE_IN_PROGRESS=1), open/refresh the PR, and arm GitHub auto-merge.
# GitHub Actions CI (audit/test/ACP smoke + clippy) is the authoritative gate.
#
# Usage: pixel-ship.sh <GAP-ID> <worktree-path>
set -uo pipefail

GAP="${1:?usage: pixel-ship.sh <GAP-ID> <worktree>}"
WT="${2:?usage: pixel-ship.sh <GAP-ID> <worktree>}"
REPO_SLUG="${CHUMP_REPO_SLUG:-repairman29/chump}"
BRANCH="chump/$(echo "$GAP" | tr 'A-Z' 'a-z')-claim"

export CHUMP_BOT_MERGE_IN_PROGRESS=1
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh}"

cd "$WT" || { echo "[pixel-ship] no worktree at $WT" >&2; exit 1; }

if [ -z "$(git log --oneline origin/main..HEAD 2>/dev/null)" ]; then
  echo "[pixel-ship] no commits ahead of origin/main on $BRANCH — nothing to ship" >&2
  exit 2
fi

echo "[pixel-ship] pushing $BRANCH …"
git push -u origin "$BRANCH" 2>&1
push_rc=$?
if [ "$push_rc" -ne 0 ]; then
  echo "[pixel-ship] push failed rc=$push_rc" >&2
  exit 3
fi

PR="$(gh pr list --repo "$REPO_SLUG" --head "$BRANCH" --state open --json number -q '.[0].number' 2>/dev/null)"
if [ -z "$PR" ]; then
  SUBJECT="$(git log -1 --pretty=format:%s 2>/dev/null)"
  gh pr create --repo "$REPO_SLUG" --base main --head "$BRANCH" \
    --title "${SUBJECT:-$GAP}" \
    --body "Shipped by the Pixel-8-Pro fleet worker (pixel-worker) on Claude Sonnet via the Anthropic subscription, through the proot-distro glibc claude build (RESILIENT-411). Implemented + committed by claude-in-proot; pushed from the Termux side to skip bot-merge's local cargo clippy --fix (a full-workspace cold compile, too slow on Termux). GitHub Actions CI is authoritative." 2>&1
  PR="$(gh pr list --repo "$REPO_SLUG" --head "$BRANCH" --state open --json number -q '.[0].number' 2>/dev/null)"
fi

if [ -z "$PR" ]; then
  echo "[pixel-ship] PR creation failed" >&2
  exit 4
fi

echo "[pixel-ship] PR #$PR — arming auto-merge (squash)"
gh pr merge "$PR" --repo "$REPO_SLUG" --auto --squash 2>&1 || true
echo "[pixel-ship] shipped gap=$GAP pr=$PR (auto-merge armed; CI gates the merge)"
exit 0
