#!/usr/bin/env bash
# chump-ci-retrigger.sh — INFRA-1407
#
# Forces a fresh-tree CI cycle on a PR by pushing an empty commit.
#
# Problem: `gh run rerun --failed` re-runs against the SAME git checkout
# snapshot that was originally used. New commits pushed to the branch since
# that snapshot are NOT picked up. This caused INFRA-1384's audit fix to be
# invisible to reruns of PRs #2097 and #2080 — the old audit code kept
# failing until a manual empty-commit (cf6ace1f) forced a fresh cycle.
#
# Solution: push an empty "ci: retrigger" commit so GitHub creates a NEW
# workflow run against the current HEAD, picking up all changes on the branch.
#
# Usage:
#   chump-ci-retrigger.sh <pr-number>
#   chump-ci-retrigger.sh <pr-number> [--reason "msg"]  # optional reason tag
#   chump-ci-retrigger.sh <pr-number> --dry-run         # print what would happen
#
# What it does:
#   1. Resolve PR head branch via `gh pr view`.
#   2. git fetch the branch.
#   3. Create a temp worktree at CHUMP_WORKTREE_BASE/chump-ci-retrigger-<pr>.
#   4. Push an empty commit: "ci: retrigger PR #<n> — force fresh CI checkout"
#   5. Emit kind=ci_retrigger_pushed to ambient.jsonl.
#   6. Clean up the temp worktree.
#
# Bypass (skip entirely):
#   CHUMP_CI_RETRIGGER=0  (no-op exits 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCKS_DIR="$REPO_ROOT/.chump-locks"
WORKTREE_BASE="${CHUMP_WORKTREE_BASE:-/tmp}"
REMOTE="${CHUMP_REMOTE:-chump}"
AMBIENT_LOG="$LOCKS_DIR/ambient.jsonl"

if [[ "${CHUMP_CI_RETRIGGER:-1}" == "0" ]]; then
    echo "[ci-retrigger] CHUMP_CI_RETRIGGER=0 — skipping" >&2
    exit 0
fi

PR_NUM=""
DRY_RUN=0
REASON=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --reason)  shift; REASON="$1" ;;
        -h|--help)
            sed -n '2,38p' "$0"
            exit 0 ;;
        [0-9]*)    PR_NUM="$arg" ;;
        *)
            echo "[ci-retrigger] unknown argument: $arg (expected PR number or --dry-run)" >&2
            exit 1 ;;
    esac
done

if [[ -z "$PR_NUM" ]]; then
    echo "[ci-retrigger] usage: chump-ci-retrigger.sh <pr-number> [--dry-run] [--reason msg]" >&2
    exit 1
fi

command -v gh >/dev/null 2>&1 || {
    echo "[ci-retrigger] gh not found — cannot look up PR branch" >&2
    exit 1
}

# 1. Resolve PR head branch.
PR_BRANCH=$(gh pr view "$PR_NUM" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
if [[ -z "$PR_BRANCH" ]]; then
    echo "[ci-retrigger] ERROR: could not resolve head branch for PR #${PR_NUM}" >&2
    exit 1
fi

PR_STATE=$(gh pr view "$PR_NUM" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
if [[ "$PR_STATE" != "OPEN" ]]; then
    echo "[ci-retrigger] PR #${PR_NUM} is ${PR_STATE} — retrigger only makes sense on OPEN PRs" >&2
    exit 1
fi

COMMIT_MSG="ci: retrigger PR #${PR_NUM} — force fresh CI checkout"
if [[ -n "$REASON" ]]; then
    COMMIT_MSG="${COMMIT_MSG} (${REASON})"
fi

if [[ "$DRY_RUN" == "1" ]]; then
    echo "[ci-retrigger] DRY-RUN: would push empty commit to '${PR_BRANCH}'" >&2
    echo "[ci-retrigger] DRY-RUN:   commit message: '${COMMIT_MSG}'" >&2
    echo "[ci-retrigger] DRY-RUN: no changes made" >&2
    exit 0
fi

# 2. Fetch current branch tip.
git fetch "$REMOTE" "$PR_BRANCH" --quiet 2>/dev/null || \
    git fetch origin "$PR_BRANCH" --quiet 2>/dev/null || true

# 3. Create temp worktree.
WT_PATH="${WORKTREE_BASE}/chump-ci-retrigger-${PR_NUM}"
WT_CLEANUP_NEEDED=0

if [[ -d "$WT_PATH" ]]; then
    git worktree remove --force "$WT_PATH" 2>/dev/null || rm -rf "$WT_PATH" || true
fi

if git worktree add "$WT_PATH" "$REMOTE/$PR_BRANCH" --detach 2>/dev/null; then
    WT_CLEANUP_NEEDED=1
elif git worktree add "$WT_PATH" "origin/$PR_BRANCH" --detach 2>/dev/null; then
    WT_CLEANUP_NEEDED=1
else
    echo "[ci-retrigger] ERROR: could not create worktree for ${PR_BRANCH}" >&2
    exit 1
fi

cleanup_wt() {
    if [[ "$WT_CLEANUP_NEEDED" == "1" && -d "$WT_PATH" ]]; then
        git worktree remove --force "$WT_PATH" 2>/dev/null || rm -rf "$WT_PATH" || true
        WT_CLEANUP_NEEDED=0
    fi
}
trap cleanup_wt EXIT

# Switch to branch (not detached HEAD) so push works.
git -C "$WT_PATH" checkout -b "retrigger-${PR_NUM}-$$" "$REMOTE/$PR_BRANCH" 2>/dev/null \
    || git -C "$WT_PATH" checkout -b "retrigger-${PR_NUM}-$$" "origin/$PR_BRANCH" 2>/dev/null

# 4. Push empty commit.
git -C "$WT_PATH" commit --allow-empty -m "$COMMIT_MSG" \
    --no-verify \
    -c "commit.gpgsign=false" 2>/dev/null || \
    GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-retrigger}" \
    GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-retrigger@chump.local}" \
    GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-retrigger}" \
    GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-retrigger@chump.local}" \
    git -C "$WT_PATH" commit --allow-empty -m "$COMMIT_MSG" --no-verify

NEW_SHA=$(git -C "$WT_PATH" rev-parse HEAD 2>/dev/null || echo "unknown")

git -C "$WT_PATH" push "$REMOTE" "HEAD:$PR_BRANCH" --no-verify 2>&1 || \
    git -C "$WT_PATH" push origin "HEAD:$PR_BRANCH" --no-verify 2>&1

echo "[ci-retrigger] pushed empty commit ${NEW_SHA:0:12} to PR #${PR_NUM} (${PR_BRANCH})" >&2
echo "[ci-retrigger] GitHub will trigger a new workflow run on the current HEAD." >&2

# 5. Emit ambient event.
mkdir -p "$LOCKS_DIR" 2>/dev/null || true
_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 'unknown')"
printf '{"ts":"%s","kind":"ci_retrigger_pushed","pr":%s,"branch":"%s","sha":"%s","reason":"%s"}\n' \
    "$_ts" "$PR_NUM" "$PR_BRANCH" "${NEW_SHA:0:12}" "${REASON:-}" \
    >> "$AMBIENT_LOG" 2>/dev/null || true

# 6. Cleanup handled by trap.
exit 0
