#!/usr/bin/env bash
# rebase-stacked-prs.sh — INFRA-765
#
# Monitors a PR for merge and, once merged, rebases all open PRs that were
# stacked on that PR's branch onto origin/main. Fires auto-merge re-arm on
# each successfully rebased PR.
#
# Usage:
#   scripts/coord/rebase-stacked-prs.sh <merged-pr-number> <merged-branch> [<repo-root>]
#
# Typically called from bot-merge.sh (fire-and-forget via nohup) after
# auto-merge is armed for the base PR. Kill switch: CHUMP_AUTO_REBASE_STACKED=0.
#
# Exit codes:
#   0 — all stacked PRs rebased (or none found)
#   1 — one or more rebases failed
#   2 — bad args

set -euo pipefail

PR_NUM="${1:-}"
MERGED_BRANCH="${2:-}"
REPO_ROOT="${3:-$(git rev-parse --show-toplevel 2>/dev/null || echo ".")}"
REMOTE="${REMOTE:-origin}"
MAX_WAIT_SECS="${CHUMP_STACKED_REBASE_WAIT_S:-3600}"  # max 1h wait for base to merge

if [[ -z "$PR_NUM" || -z "$MERGED_BRANCH" ]]; then
    echo "Usage: $0 <pr-number> <branch-name> [<repo-root>]" >&2
    exit 2
fi

AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMB")" 2>/dev/null || true

log() { echo "[rebase-stacked] $*" >&2; }
emit() {
    printf '%s\n' "$1" >> "$AMB" 2>/dev/null || true
}

log "INFRA-765: monitoring PR #$PR_NUM ($MERGED_BRANCH) for merge"
log "  Will rebase stacked PRs onto origin/main when base merges"
log "  Kill switch: CHUMP_AUTO_REBASE_STACKED=0"

# ── Wait for the base PR to merge ─────────────────────────────────────────────
_start_ts=$(date +%s)
_merged=0
while true; do
    _elapsed=$(( $(date +%s) - _start_ts ))
    if [[ "$_elapsed" -ge "$MAX_WAIT_SECS" ]]; then
        log "WARN: timed out waiting for PR #$PR_NUM to merge after ${MAX_WAIT_SECS}s — giving up"
        exit 0
    fi

    _state=$(gh pr view "$PR_NUM" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
    if [[ "$_state" == "MERGED" ]]; then
        _merged=1
        break
    elif [[ "$_state" == "CLOSED" ]]; then
        log "PR #$PR_NUM was closed (not merged) — no stacked PR rebase needed"
        exit 0
    fi

    log "PR #$PR_NUM state=$_state — waiting 30s"
    sleep 30
done

log "PR #$PR_NUM merged — scanning for stacked PRs with base=$MERGED_BRANCH"

# ── Find stacked PRs ──────────────────────────────────────────────────────────
_stacked_prs=$(gh pr list \
    --base "$MERGED_BRANCH" \
    --state open \
    --json number,headRefName,title \
    --jq '.[] | "\(.number)|\(.headRefName)|\(.title)"' \
    2>/dev/null || true)

if [[ -z "$_stacked_prs" ]]; then
    log "No open PRs stacked on $MERGED_BRANCH — nothing to rebase"
    emit '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","kind":"stacked_pr_rebase_scan","merged_branch":"'"$MERGED_BRANCH"'","stacked_count":0}'
    exit 0
fi

_count=$(echo "$_stacked_prs" | wc -l | tr -d ' ')
log "Found $_count stacked PR(s) on $MERGED_BRANCH — rebasing onto origin/main"

emit '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","kind":"stacked_pr_rebase_scan","merged_branch":"'"$MERGED_BRANCH"'","stacked_count":'"$_count"'}'

# Fetch origin/main for rebase
git -C "$REPO_ROOT" fetch "$REMOTE" main --quiet 2>/dev/null || true

_fail_count=0
while IFS='|' read -r _pr_num _branch _title; do
    [[ -z "$_pr_num" ]] && continue
    log "  Rebasing PR #$_pr_num ($MERGED_BRANCH → main): $_branch"

    # Create temp branch for rebase (avoids polluting checked-out branch)
    _tmp_branch="_infra765_rebase_$(date +%s)"
    _rebased=0
    _err=""

    (
        cd "$REPO_ROOT" || exit 1
        # Fetch the stacked branch
        git fetch "$REMOTE" "$_branch" --quiet 2>/dev/null
        # Create temp local branch at the stacked PR's HEAD
        git checkout -B "$_tmp_branch" "$REMOTE/$_branch" --quiet 2>/dev/null
        # Rebase onto origin/main
        git rebase "$REMOTE/main" --quiet 2>/dev/null
        # Force-push to update the stacked PR's branch
        git push --force-with-lease "$REMOTE" "${_tmp_branch}:${_branch}" --quiet 2>/dev/null
        # Clean up temp branch
        git checkout - --quiet 2>/dev/null || true
        git branch -D "$_tmp_branch" --quiet 2>/dev/null || true
    ) && _rebased=1 || _err="$?"

    # Clean up temp branch if left behind
    git -C "$REPO_ROOT" branch -D "$_tmp_branch" --quiet 2>/dev/null || true

    if [[ "$_rebased" -eq 1 ]]; then
        log "  PR #$_pr_num rebased onto main — re-arming auto-merge"
        # INFRA-1223: route through centralized armer to inherit 5s spacing +
        # secondary-rate-limit backoff. Loops over stacked PRs without the
        # armer's enforcement risk gagging the operator's user account.
        "${REPO_ROOT}/scripts/coord/auto-merge-armer.sh" --pr "$_pr_num" 2>/dev/null || \
            log "  WARN: could not re-arm auto-merge on PR #$_pr_num (already armed?)"

        emit '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","kind":"stacked_pr_rebased","merged_branch":"'"$MERGED_BRANCH"'","stacked_pr":'"$_pr_num"',"stacked_branch":"'"$_branch"'","status":"ok"}'
        log "  PR #$_pr_num: done ✓"
    else
        log "  WARN: PR #$_pr_num rebase failed (err=$_err) — manual rebase needed"
        emit '{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","kind":"stacked_pr_rebased","merged_branch":"'"$MERGED_BRANCH"'","stacked_pr":'"$_pr_num"',"stacked_branch":"'"$_branch"'","status":"failed","err":"'"$_err"'"}'
        _fail_count=$((_fail_count + 1))
    fi

done <<< "$_stacked_prs"

if [[ "$_fail_count" -gt 0 ]]; then
    log "WARN: $_fail_count stacked PR(s) failed to rebase — check log for details"
    exit 1
fi

log "INFRA-765: all stacked PRs rebased successfully"
exit 0
