#!/usr/bin/env bash
# rollback-gap.sh — INFRA-899
#
# Automated gap rollback: kills agent, releases lease, removes worktree,
# deletes branch, resets gap status to open, emits kind=gap_rollback_executed.
#
# Usage:
#   rollback-gap.sh [OPTIONS] <GAP-ID>
#
# Options:
#   --dry-run    Print what would happen; make no changes
#   --force      Roll back even if gap appears healthy (use with care)
#   --keep-branch  Do not delete the git branch (useful for debugging)
#   -h|--help    Print this help
#
# Environment:
#   REPO_ROOT           Repo root (auto-detected)
#   CHUMP_AMBIENT_LOG   Path to ambient.jsonl
#
# Exit codes:
#   0  Rollback succeeded (or --dry-run completed)
#   1  Error (gap not found, lease not found in non-force mode)
#   2  Usage error

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMB="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN=0
FORCE=0
KEEP_BRANCH=0
GAP_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=1; shift ;;
        --force)        FORCE=1; shift ;;
        --keep-branch)  KEEP_BRANCH=1; shift ;;
        -h|--help)
            grep '^#' "$0" | head -25 | sed 's/^# \?//'
            exit 0 ;;
        -*)  echo "Unknown option: $1" >&2; exit 2 ;;
        *)
            if [[ -z "$GAP_ID" ]]; then GAP_ID="$1"
            else echo "Unexpected argument: $1" >&2; exit 2
            fi
            shift ;;
    esac
done

if [[ -z "$GAP_ID" ]]; then
    echo "Usage: rollback-gap.sh [OPTIONS] <GAP-ID>" >&2
    exit 2
fi

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { echo "[rollback-gap] $*" >&2; }
_dry() { echo "[dry-run] $*" >&2; }

WORKTREE_REMOVED=false
BRANCH_DELETED=false
LEASE_RELEASED=false

GAP_LOWER=$(echo "$GAP_ID" | tr '[:upper:]' '[:lower:]')  # infra-899

# ── Step 0: Locate lease file ─────────────────────────────────────────────────
LEASE_GLOB="$REPO_ROOT/.chump-locks/claim-${GAP_LOWER}-*.json"
# shellcheck disable=SC2206
LEASE_FILES=( $LEASE_GLOB ) 2>/dev/null || true
LEASE_FILE=""
for f in "${LEASE_FILES[@]}"; do
    [[ -f "$f" ]] && LEASE_FILE="$f" && break
done

if [[ -z "$LEASE_FILE" ]] && [[ "$FORCE" -eq 0 ]]; then
    _log "No lease found for $GAP_ID (glob: $LEASE_GLOB)"
    _log "Use --force to rollback even without an active lease"
    exit 1
fi

_log "Rolling back: $GAP_ID"
[[ -n "$LEASE_FILE" ]] && _log "  lease: $LEASE_FILE"

# ── Step 1: Kill agent tmux pane ──────────────────────────────────────────────
PANE_ID=$(tmux list-panes -a -F "#{pane_id} #{pane_title}" 2>/dev/null | \
    grep -i "$GAP_LOWER\|${GAP_ID}" | awk '{print $1}' | head -1 || true)

if [[ -n "$PANE_ID" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _dry "would kill tmux pane: $PANE_ID"
    else
        _log "Killing tmux pane: $PANE_ID"
        tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
    fi
fi

# ── Step 2: Release lease ─────────────────────────────────────────────────────
if [[ -n "$LEASE_FILE" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _dry "would release lease: $LEASE_FILE"
    else
        _log "Releasing lease: $LEASE_FILE"
        # Try chump --release first (updates state.db), then always remove file
        if command -v chump >/dev/null 2>&1; then
            chump --release --lease "$LEASE_FILE" 2>/dev/null || true
        fi
        rm -f "$LEASE_FILE"
        LEASE_RELEASED=true
    fi
fi

# ── Step 3: Remove worktree ───────────────────────────────────────────────────
WORKTREE_PATH=$(git -C "$REPO_ROOT" worktree list 2>/dev/null | \
    grep -i "$GAP_LOWER\|${GAP_ID}" | awk '{print $1}' | head -1 || true)

if [[ -n "$WORKTREE_PATH" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _dry "would remove worktree: $WORKTREE_PATH"
    else
        _log "Removing worktree: $WORKTREE_PATH"
        git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || \
            rm -rf "$WORKTREE_PATH"
        git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
        WORKTREE_REMOVED=true
    fi
elif [[ -d "/tmp/chump-${GAP_LOWER}" ]] || [[ -d "/private/tmp/chump-${GAP_LOWER}" ]]; then
    # Fallback: worktree path known by convention even if not in git worktree list
    FALLBACK_PATH="/private/tmp/chump-${GAP_LOWER}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _dry "would remove orphaned worktree dir: $FALLBACK_PATH"
    else
        _log "Removing orphaned worktree dir: $FALLBACK_PATH"
        rm -rf "$FALLBACK_PATH"
        git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
        WORKTREE_REMOVED=true
    fi
fi

# ── Step 4: Delete branch ─────────────────────────────────────────────────────
if [[ "$KEEP_BRANCH" -eq 0 ]]; then
    BRANCH=$(git -C "$REPO_ROOT" branch --list "*${GAP_LOWER}*claim*" | \
        tr -d ' *' | head -1 || true)

    if [[ -n "$BRANCH" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            _dry "would delete branch: $BRANCH (local + remote)"
        else
            _log "Deleting local branch: $BRANCH"
            git -C "$REPO_ROOT" branch -D "$BRANCH" 2>/dev/null || true
            _log "Deleting remote branch: $BRANCH (best-effort)"
            git -C "$REPO_ROOT" push origin --delete "$BRANCH" 2>/dev/null || true
            BRANCH_DELETED=true
        fi
    fi
fi

# ── Step 5: Reset gap status to open ─────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    _dry "would reset $GAP_ID status to open"
else
    if command -v chump >/dev/null 2>&1; then
        _log "Resetting $GAP_ID status to open"
        chump gap set "$GAP_ID" status open 2>/dev/null || \
            _log "WARN: could not reset gap status (chump gap set failed)"
        NOTE="Rolled back on $(_ts) by rollback-gap.sh. Re-pick after diagnosing failure."
        chump gap set "$GAP_ID" notes "$NOTE" 2>/dev/null || true
    else
        _log "WARN: chump not found — skipping gap status reset"
    fi
fi

# ── Step 6: Emit ambient event ────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    _dry "would emit kind=gap_rollback_executed to $AMB"
else
    TS="$(_ts)"
    PAYLOAD=$(printf '{"ts":"%s","kind":"gap_rollback_executed","gap_id":"%s","worktree_removed":%s,"branch_deleted":%s,"lease_released":%s,"operator":"rollback-gap.sh"}' \
        "$TS" "$GAP_ID" "$WORKTREE_REMOVED" "$BRANCH_DELETED" "$LEASE_RELEASED")
    mkdir -p "$(dirname "$AMB")"
    printf '%s\n' "$PAYLOAD" >> "$AMB"
    _log "Emitted gap_rollback_executed to ambient"
fi

# ── Step 7: Summary ───────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    _dry "Dry run complete — no changes made"
else
    _log "Rollback complete for $GAP_ID"
    _log "  worktree_removed=$WORKTREE_REMOVED  branch_deleted=$BRANCH_DELETED  lease_released=$LEASE_RELEASED"
    _log "Next step: chump gap show $GAP_ID  (should be status=open)"
fi
