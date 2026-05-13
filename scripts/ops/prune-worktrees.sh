#!/usr/bin/env bash
# prune-worktrees.sh — RESILIENT-013: orphaned /tmp/chump-* worktree reaper
#
# Modes:
#   orphan (default): Find /tmp/chump-* directories that are git worktrees,
#     check if they have an active lease in .chump-locks/, and if the
#     corresponding branch has an open PR. Prune if:
#       - No active (non-expired) lease in .chump-locks/, AND
#       - No open PR found for the branch (via gh REST API)
#
# Why this exists
#   Fleet sessions leave /tmp/chump-* worktrees behind when they crash,
#   get killed, or forget to clean up. These accumulate disk pressure,
#   slow `git worktree list`, and confuse future sessions about what work
#   is in flight. RESILIENT-013 adds a reaper that prunes orphans safely.
#
# What it does NOT do
#   - Prune worktrees with active leases (session may be mid-work)
#   - Prune worktrees with open PRs (branch may still be under review)
#   - Prune .claude/worktrees/ (that's stale-worktree-reaper.sh's job)
#   - Force-delete — uses `git worktree remove` to be safe
#
# Bypass: CHUMP_SKIP_ORPHAN_PRUNE=1
#
# Usage:
#   bash scripts/ops/prune-worktrees.sh [--dry-run] [--scan-dir /tmp]
#
# Emits to ambient.jsonl:
#   kind=worktree_orphan_pruned  (one per pruned worktree)
#   kind=worktree_orphan_skipped (one per skipped worktree with reason)

set -uo pipefail

DRY_RUN=false
SCAN_DIR="/tmp"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --scan-dir) SCAN_DIR="$2"; shift 2 ;;
        *) echo "[prune-worktrees] unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ "${CHUMP_SKIP_ORPHAN_PRUNE:-0}" == "1" ]]; then
    echo "[prune-worktrees] CHUMP_SKIP_ORPHAN_PRUNE=1 — skipping" >&2
    exit 0
fi

# Detect repo slug from git remote for gh PR lookup.
REPO_SLUG="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's|.*github.com[:/]||; s|\.git$||')" || REPO_SLUG=""

emit_ambient() {
    local kind="$1"; shift
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local payload; payload="$(printf '{"ts":"%s","kind":"%s",%s}' "$ts" "$kind" "$*")"
    echo "$payload" >> "$AMBIENT" 2>/dev/null || true
    echo "[prune-worktrees] $payload"
}

# Check if a lease is active (file exists AND not expired).
is_active_lease() {
    local worktree_path="$1"
    local branch="$2"
    local now_ts; now_ts="$(date -u +%s)"
    local found=0

    while IFS= read -r lease_file; do
        [[ -f "$lease_file" ]] || continue
        # Match by worktree path or branch name in the lease JSON.
        local worktree_match branch_match
        worktree_match=$(python3 -c "import json; d=json.load(open('$lease_file')); print(d.get('worktree',''))" 2>/dev/null || echo "")
        branch_match=$(python3 -c "import json; d=json.load(open('$lease_file')); print(d.get('branch',''))" 2>/dev/null || echo "")

        # Also check the gap_id field maps to a worktree path.
        if [[ "$worktree_match" == "$worktree_path" || "$worktree_match" == "/private${worktree_path}" \
            || "$branch_match" == "$branch" ]]; then
            # Check expiry.
            local expires_at
            expires_at=$(python3 -c "import json; d=json.load(open('$lease_file')); print(d.get('expires_at',''))" 2>/dev/null || echo "")
            if [[ -n "$expires_at" ]]; then
                local exp_ts
                exp_ts=$(date -d "$expires_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires_at" +%s 2>/dev/null || echo 0)
                if [[ "$exp_ts" -gt "$now_ts" ]]; then
                    found=1
                    break
                fi
            else
                # No expiry field — treat as active (conservative).
                found=1
                break
            fi
        fi
    done < <(find "$LOCK_DIR" -maxdepth 1 -name "*.json" 2>/dev/null)

    [[ "$found" -eq 1 ]]
}

# Check if there's an open PR for the given branch on GitHub.
has_open_pr() {
    local branch="$1"
    # CHUMP_SKIP_PR_CHECK=1: skip PR check entirely (for offline/test use).
    # Also skips when REPO_SLUG is empty, unless CHUMP_SKIP_PR_CHECK=1 was set.
    if [[ "${CHUMP_SKIP_PR_CHECK:-0}" == "1" ]]; then
        return 1  # Treat as "no open PR" — allow pruning.
    fi
    if [[ -z "$REPO_SLUG" ]] || ! command -v gh &>/dev/null; then
        # Can't check — be conservative (skip pruning).
        return 0
    fi
    local pr_count
    pr_count=$(gh api "repos/$REPO_SLUG/pulls?state=open&head=${REPO_SLUG%%/*}:${branch}&per_page=1" \
        --jq 'length' 2>/dev/null || echo 1)
    [[ "${pr_count:-1}" -gt 0 ]]
}

PRUNED=0
SKIPPED=0
ERRORS=0

echo "[prune-worktrees] scanning $SCAN_DIR/chump-* for orphaned worktrees (dry_run=$DRY_RUN)"

while IFS= read -r wt_dir; do
    [[ -d "$wt_dir" ]] || continue

    # Must be a git worktree — check for .git file (linked worktrees have a .git file, not dir).
    if [[ ! -f "$wt_dir/.git" ]] && [[ ! -d "$wt_dir/.git" ]]; then
        continue
    fi

    # Get the branch name.
    branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
        echo "[prune-worktrees] SKIP $wt_dir — could not determine branch" >&2
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo "[prune-worktrees] checking $wt_dir (branch=$branch)"

    # Safety: skip if there are uncommitted changes.
    if ! git -C "$wt_dir" diff --quiet HEAD 2>/dev/null; then
        echo "[prune-worktrees] SKIP $wt_dir — has uncommitted changes"
        emit_ambient "worktree_orphan_skipped" "\"path\":\"$wt_dir\",\"reason\":\"uncommitted_changes\",\"branch\":\"$branch\""
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check active lease.
    if is_active_lease "$wt_dir" "$branch"; then
        echo "[prune-worktrees] SKIP $wt_dir — active lease found"
        emit_ambient "worktree_orphan_skipped" "\"path\":\"$wt_dir\",\"reason\":\"active_lease\",\"branch\":\"$branch\""
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Check open PR.
    if has_open_pr "$branch"; then
        echo "[prune-worktrees] SKIP $wt_dir — open PR for branch $branch"
        emit_ambient "worktree_orphan_skipped" "\"path\":\"$wt_dir\",\"reason\":\"open_pr\",\"branch\":\"$branch\""
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Safe to prune.
    echo "[prune-worktrees] PRUNE $wt_dir (no lease, no open PR, no uncommitted changes)"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[prune-worktrees]   [dry-run] would remove $wt_dir"
        PRUNED=$((PRUNED + 1))
    else
        # git worktree remove also prunes the gitdir metadata.
        if git -C "$REPO_ROOT" worktree remove --force "$wt_dir" 2>/dev/null; then
            emit_ambient "worktree_orphan_pruned" "\"path\":\"$wt_dir\",\"branch\":\"$branch\""
            PRUNED=$((PRUNED + 1))
        else
            # Fallback: manual rm if worktree remove fails (e.g. wrong gitdir).
            if rm -rf "$wt_dir"; then
                # Also prune the stale gitdir reference.
                git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
                emit_ambient "worktree_orphan_pruned" "\"path\":\"$wt_dir\",\"branch\":\"$branch\",\"method\":\"rm_fallback\""
                PRUNED=$((PRUNED + 1))
            else
                echo "[prune-worktrees] ERROR: could not remove $wt_dir" >&2
                ERRORS=$((ERRORS + 1))
            fi
        fi
    fi
done < <(find "$SCAN_DIR" -maxdepth 1 -name "chump-*" -type d 2>/dev/null | sort)

echo ""
echo "[prune-worktrees] done: pruned=$PRUNED skipped=$SKIPPED errors=$ERRORS dry_run=$DRY_RUN"
