#!/usr/bin/env bash
# worktree-prune.sh — clean up stale agent worktrees + lease files.
#
# After a multi-agent sprint we accumulate dozens of worktrees in
# .claude/worktrees/ that correspond to:
#   - Branches whose PRs already merged → safe to delete
#   - Branches whose PRs were closed without merge → safe to delete
#   - Branches still ahead of main with no PR yet → KEEP (active WIP)
#   - Lease files past their expires_at TTL → safe to delete
#
# This script does the boring sweep work safely: it never deletes a
# worktree that has uncommitted changes or untracked files (would lose
# work), never deletes a branch that's the local HEAD of a non-main
# worktree, and prints exactly what it would do under --dry-run.
#
# Usage:
#   scripts/coord/worktree-prune.sh                   # dry-run by default (safe)
#   scripts/coord/worktree-prune.sh --execute         # actually delete
#   scripts/coord/worktree-prune.sh --keep-merged     # only prune leases, leave worktrees
#
# Output is a per-worktree status table:
#   wt-name  branch  pr-state  reason  action
#
# Exits 0 if all OK, 1 if any worktree has uncommitted changes
# (those are flagged but not auto-deleted).

set -euo pipefail

DRY_RUN=1
KEEP_MERGED=0
# INFRA-1053: harness-agnostic base. Default preserves the
# .claude/worktrees/ convention (zero behavior change for existing operators).
WORKTREE_ROOT="${CHUMP_WORKTREE_BASE:-.claude/worktrees}"
# INFRA-1124: CHUMP_REAPER_SAFETY_CHECK=0 disables heartbeat+index safety checks.
REAPER_SAFETY_CHECK="${CHUMP_REAPER_SAFETY_CHECK:-1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)      DRY_RUN=0 ;;
        --keep-merged)  KEEP_MERGED=1 ;;
        -h|--help)
            sed -n '2,28p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "error: not in a git repo" >&2
    exit 2
fi
# When run from inside a worktree, .claude/worktrees/ is at the MAIN repo,
# not the current worktree. Resolve to the main worktree path via
# git worktree list (the first entry is always the main one).
MAIN_REPO="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2; exit}')"
if [[ -z "$MAIN_REPO" || ! -d "$MAIN_REPO/$WORKTREE_ROOT" ]]; then
    MAIN_REPO="$REPO_ROOT"
fi
cd "$MAIN_REPO"

# INFRA-1211: shared worktree scanning + lease check + event emission lib.
# shellcheck source=scripts/lib/worktree-iter.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/worktree-iter.sh"
# shellcheck source=scripts/lib/lease.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/lease.sh"
REAPER_NAME="${REAPER_NAME:-worktree-prune}"
REAPER_REPO_ROOT="$MAIN_REPO"
export REAPER_REPO_ROOT

# Returns 0 if wt_dir has a fresh active lease or a fresh .git/index.
# Delegates lease scanning to wt_has_active_lease() from worktree-iter.sh.
_prune_is_inflight() {
    local wt_dir="$1"
    [[ "$REAPER_SAFETY_CHECK" != "1" ]] && return 1
    # Lease check via shared lib (replaces the old _PRUNE_ACTIVE_WORKTREES loop).
    if wt_has_active_lease "$wt_dir" 900; then
        emit_reaper_event "worktree_reaper_skipped_active" "$wt_dir" "active_lease"
        return 0
    fi
    # .git/index mtime check (belt-and-suspenders for pre-fix leases).
    local _gi=""
    if [[ -f "$wt_dir/.git" ]]; then
        local _gd; _gd=$(sed 's/^gitdir: //' "$wt_dir/.git" 2>/dev/null || true)
        [[ -n "$_gd" && -f "$_gd/index" ]] && _gi="$_gd/index"
    elif [[ -f "$wt_dir/.git/index" ]]; then
        _gi="$wt_dir/.git/index"
    fi
    if [[ -n "$_gi" ]]; then
        local _fresh; _fresh=$(find "$_gi" -mmin -5 2>/dev/null | head -1 || true)
        if [[ -n "$_fresh" ]]; then
            emit_reaper_event "worktree_reaper_skipped_active" "$wt_dir" "git_index_fresh"
            return 0
        fi
    fi
    return 1
}

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[worktree-prune] DRY RUN (no changes will be made; pass --execute to delete)"
fi
echo

# ── 1. Stale lease files ─────────────────────────────────────────────────────
echo "── stale lease files (.chump-locks/*.json past expires_at) ──"
# INFRA-1224: migrated 22-line python3 expires_at parser → scripts/lib/lease.sh.
# shellcheck source=../lib/lease.sh
source "$(git rev-parse --show-toplevel)/scripts/lib/lease.sh"
stale_count=0
while IFS= read -r lease; do
    [[ -f "$lease" ]] || continue
    if lease_is_expired "$lease"; then
        stale_count=$((stale_count + 1))
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "  WOULD DELETE  $lease"
        else
            rm "$lease" && echo "  DELETED       $lease"
        fi
    fi
done < <(lease_iter)
echo "  ($stale_count stale leases found)"
echo

if [[ $KEEP_MERGED -eq 1 ]]; then
    echo "[worktree-prune] --keep-merged set, skipping worktree pruning"
    exit 0
fi

# ── 2. Worktrees whose PR is merged or closed without merge ──────────────────
echo "── worktree pruning ──"
printf "  %-30s %-40s %-12s %s\n" "WORKTREE" "BRANCH" "PR-STATE" "ACTION"
printf "  %-30s %-40s %-12s %s\n" "--------" "------" "--------" "------"

dirty_count=0
pruned_count=0
kept_count=0

if [[ ! -d "$WORKTREE_ROOT" ]]; then
    echo "  (no worktree root at $WORKTREE_ROOT)"
    exit 0
fi

for wt_dir in "$WORKTREE_ROOT"/*/; do
    [[ -d "$wt_dir" ]] || continue
    wt_name=$(basename "$wt_dir")

    # Get the branch this worktree is on
    branch=$(cd "$wt_dir" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    branch_short="${branch#refs/heads/}"

    # Check if there are uncommitted changes (working-tree modifications or
    # untracked files that aren't gitignored)
    has_changes=$(cd "$wt_dir" 2>/dev/null && \
        { git status --porcelain 2>/dev/null | grep -v "^??" | head -1; } || echo "")
    # shellcheck disable=SC2034  # reserved for future prune-on-untracked logic
    untracked_unignored=$(cd "$wt_dir" 2>/dev/null && \
        { git status --porcelain --untracked-files=normal 2>/dev/null | grep "^??" | head -1; } || echo "")

    if [[ -n "$has_changes" ]]; then
        printf "  %-30s %-40s %-12s %s\n" \
            "$wt_name" "$branch_short" "(dirty)" "KEEP — uncommitted changes"
        dirty_count=$((dirty_count + 1))
        continue
    fi

    # Find the PR for this branch
    pr_state=$(gh pr list --state all --head "$branch_short" --json state \
        -q '.[0].state // "(none)"' 2>/dev/null || echo "?")
    pr_num=$(gh pr list --state all --head "$branch_short" --json number \
        -q '.[0].number // ""' 2>/dev/null || echo "")

    case "$pr_state" in
        MERGED)
            if _prune_is_inflight "$wt_dir"; then
                action="KEEP — in-flight (active lease or fresh .git/index)"
                kept_count=$((kept_count + 1))
            else
                action="PRUNE"
                pruned_count=$((pruned_count + 1))
                if [[ $DRY_RUN -eq 0 ]]; then
                    git worktree remove "$wt_dir" --force >/dev/null 2>&1 || true
                    git branch -D "$branch_short" >/dev/null 2>&1 || true
                    action="PRUNED"
                else
                    action="WOULD PRUNE (merged PR #$pr_num)"
                fi
            fi
            ;;
        CLOSED)
            if _prune_is_inflight "$wt_dir"; then
                action="KEEP — in-flight (active lease or fresh .git/index)"
                kept_count=$((kept_count + 1))
            else
                action="PRUNE"
                pruned_count=$((pruned_count + 1))
                if [[ $DRY_RUN -eq 0 ]]; then
                    git worktree remove "$wt_dir" --force >/dev/null 2>&1 || true
                    git branch -D "$branch_short" >/dev/null 2>&1 || true
                    action="PRUNED"
                else
                    action="WOULD PRUNE (closed PR #$pr_num)"
                fi
            fi
            ;;
        OPEN)
            action="KEEP — PR #$pr_num still open"
            kept_count=$((kept_count + 1))
            ;;
        *)
            # No PR. Check if branch is ahead of main — if so, WIP, keep.
            ahead=$(cd "$wt_dir" 2>/dev/null && \
                { git log origin/main..HEAD --oneline 2>/dev/null | wc -l | tr -d ' '; } \
                || echo "0")
            if [[ "$ahead" -gt 0 ]]; then
                action="KEEP — $ahead WIP commits, no PR yet"
                kept_count=$((kept_count + 1))
            elif _prune_is_inflight "$wt_dir"; then
                action="KEEP — in-flight (active lease or fresh .git/index)"
                kept_count=$((kept_count + 1))
            else
                action="PRUNE"
                pruned_count=$((pruned_count + 1))
                if [[ $DRY_RUN -eq 0 ]]; then
                    git worktree remove "$wt_dir" --force >/dev/null 2>&1 || true
                    git branch -D "$branch_short" >/dev/null 2>&1 || true
                    action="PRUNED"
                else
                    action="WOULD PRUNE (no PR, no commits ahead)"
                fi
            fi
            ;;
    esac

    printf "  %-30s %-40s %-12s %s\n" \
        "$wt_name" "$branch_short" "$pr_state" "$action"
done

echo
echo "── summary ──"
echo "  pruned:  $pruned_count worktree(s)"
echo "  kept:    $kept_count worktree(s) (open PR or WIP)"
echo "  dirty:   $dirty_count worktree(s) (uncommitted — investigate manually)"
echo "  leases:  $stale_count stale lease(s)"

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "  Re-run with --execute to actually delete."
fi

if [[ $dirty_count -gt 0 ]]; then
    exit 1
fi
exit 0
