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
#   scripts/worktree-prune.sh                   # dry-run by default (safe)
#   scripts/worktree-prune.sh --execute         # actually delete
#   scripts/worktree-prune.sh --keep-merged     # only prune leases, leave worktrees
#
# Output is a per-worktree status table:
#   wt-name  branch  pr-state  reason  action
#
# Exits 0 if all OK, 1 if any worktree has uncommitted changes
# (those are flagged but not auto-deleted).

set -euo pipefail

DRY_RUN=1
KEEP_MERGED=0
WORKTREE_ROOT=".claude/worktrees"

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

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[worktree-prune] DRY RUN (no changes will be made; pass --execute to delete)"
fi
echo

# ── 1. Stale lease files ─────────────────────────────────────────────────────
echo "── stale lease files (.chump-locks/*.json past expires_at) ──"
stale_count=0
if compgen -G ".chump-locks/*.json" > /dev/null 2>&1; then
    for lease in .chump-locks/*.json; do
        [[ -f "$lease" ]] || continue
        # Parse expires_at; use python because jq isn't guaranteed and shell
        # can't compare ISO dates portably.
        expired=$(python3 -c "
import json, sys, datetime
try:
    d = json.load(open('$lease'))
    exp = d.get('expires_at')
    if not exp:
        sys.exit(2)
    e = datetime.datetime.fromisoformat(exp.replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    print('expired' if now > e else 'live')
except Exception as ex:
    print('error: ' + str(ex))
    sys.exit(2)
" 2>/dev/null)
        if [[ "$expired" == "expired" ]]; then
            stale_count=$((stale_count + 1))
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "  WOULD DELETE  $lease"
            else
                rm "$lease" && echo "  DELETED       $lease"
            fi
        fi
    done
fi
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
            action="PRUNE"
            pruned_count=$((pruned_count + 1))
            if [[ $DRY_RUN -eq 0 ]]; then
                git worktree remove "$wt_dir" --force >/dev/null 2>&1 || true
                git branch -D "$branch_short" >/dev/null 2>&1 || true
                action="PRUNED"
            else
                action="WOULD PRUNE (merged PR #$pr_num)"
            fi
            ;;
        CLOSED)
            action="PRUNE"
            pruned_count=$((pruned_count + 1))
            if [[ $DRY_RUN -eq 0 ]]; then
                git worktree remove "$wt_dir" --force >/dev/null 2>&1 || true
                git branch -D "$branch_short" >/dev/null 2>&1 || true
                action="PRUNED"
            else
                action="WOULD PRUNE (closed PR #$pr_num)"
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
