#!/usr/bin/env bash
# scripts/coord/branch-reaper.sh — INFRA-1058 (2026-05-14)
#
# Prunes stale remote branches whose PRs have been merged or closed > 7 days ago.
#
# Prevents accumulation of zombie remote refs from squash-merged PRs. GitHub's
# "Automatically delete head branches" setting handles new merges but doesn't
# backfill historical refs from before it was enabled.
#
# Usage:
#   branch-reaper.sh [--dry-run] [--min-age-days N] [--keep-list branch1,branch2,...]
#
# Options:
#   --dry-run            Print what would be pruned without deleting (DEFAULT)
#   --act                Actually delete branches (requires explicit flag)
#   --min-age-days N     Only prune PRs closed/merged > N days ago (default: 7)
#   --keep-list LIST     Comma-separated additional branch names to protect
#
# Protected branches (never pruned):
#   main, master, release/*, gh-readonly-queue/*, develop, staging
#
# Exit codes:
#   0 — success (including empty prune list)
#   1 — usage or GitHub API error

set -uo pipefail

# ── Resolve repo root and ambient log ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/repo-paths.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/repo-paths.sh"
# INFRA-1211: worktree-iter lib for shared event emission.
# shellcheck source=../lib/worktree-iter.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/worktree-iter.sh"
REAPER_NAME="${REAPER_NAME:-branch-reaper}"
REAPER_REPO_ROOT="$REPO_ROOT"
export REAPER_REPO_ROOT

AMBIENT="$LOCK_DIR/ambient.jsonl"

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=1   # default: dry-run mode (safe)
MIN_AGE_DAYS=7
EXTRA_KEEP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1 ;;
        --act)        DRY_RUN=0 ;;
        --min-age-days)
            shift; MIN_AGE_DAYS="$1" ;;
        --keep-list)
            shift; EXTRA_KEEP="$1" ;;
        --help|-h)
            echo "Usage: branch-reaper.sh [--dry-run|--act] [--min-age-days N] [--keep-list b1,b2]"
            exit 0 ;;
        *)
            echo "Unknown flag: $1" >&2
            exit 1 ;;
    esac
    shift
done

# ── Resolve repo (owner/name) ─────────────────────────────────────────────────
REPO="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
if [[ -z "$REPO" ]]; then
    echo "[branch-reaper] ERROR: cannot resolve GitHub repo from remote." >&2
    exit 1
fi

# ── Protected branches list ───────────────────────────────────────────────────
# Never delete these regardless of PR status.
PROTECT_PATTERNS=(
    "main"
    "master"
    "develop"
    "staging"
    "production"
    "release/*"
    "gh-readonly-queue/*"
    "release-plz-*"
)
# Add extra keep-list entries
if [[ -n "$EXTRA_KEEP" ]]; then
    IFS=',' read -ra extra_arr <<< "$EXTRA_KEEP"
    PROTECT_PATTERNS+=("${extra_arr[@]}")
fi

_is_protected() {
    local branch="$1"
    for pattern in "${PROTECT_PATTERNS[@]}"; do
        # shellcheck disable=SC2254  # glob patterns intentional in case
        case "$branch" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# ── Compute cutoff timestamp (Unix epoch) ─────────────────────────────────────
CUTOFF_EPOCH=$(( $(date -u +%s) - MIN_AGE_DAYS * 86400 ))

# ── Emit ambient event ────────────────────────────────────────────────────────
_emit_pruned() {
    local branch="$1" pr_num="$2" age_days="$3" mode="$4"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"branch_reaper_pruned","branch":"%s","pr":%s,"age_days":%s,"dry_run":%s}\n' \
        "$ts" "$branch" "$pr_num" "$age_days" "$( [[ "$mode" == "dry" ]] && echo "true" || echo "false")" \
        >> "$AMBIENT" 2>/dev/null || true
}

# ── Main loop: enumerate remote branches ─────────────────────────────────────
echo "[branch-reaper] Repo: $REPO"
echo "[branch-reaper] Min age: ${MIN_AGE_DAYS}d  Mode: $( [[ "$DRY_RUN" -eq 1 ]] && echo 'DRY-RUN' || echo 'ACT' )"
echo "[branch-reaper] Fetching remote branches..."

# Fetch all branch names from GitHub (up to 1000 refs, paginated)
ALL_BRANCHES="$(gh api "repos/$REPO/branches?per_page=100&page=1" --jq '.[].name' 2>/dev/null || true)"
for page in 2 3 4 5 6 7 8 9 10; do
    PAGE_RESULT="$(gh api "repos/$REPO/branches?per_page=100&page=$page" --jq '.[].name' 2>/dev/null || true)"
    [[ -z "$PAGE_RESULT" ]] && break
    ALL_BRANCHES+=$'\n'"$PAGE_RESULT"
done

TOTAL=$(echo "$ALL_BRANCHES" | grep -c . || echo 0)
echo "[branch-reaper] Total remote branches: $TOTAL"

PRUNED=0
SKIPPED=0
PROTECTED=0

while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue

    # ── Skip protected branches ───────────────────────────────────────────────
    if _is_protected "$branch"; then
        PROTECTED=$((PROTECTED+1))
        continue
    fi

    # ── Find the corresponding PR ─────────────────────────────────────────────
    # Look for a closed/merged PR with this branch as head.
    PR_DATA="$(gh api "repos/$REPO/pulls?state=closed&head=${REPO%%/*}:${branch}&per_page=1" \
        --jq '.[0] | {number: .number, merged_at: .merged_at, closed_at: .closed_at, state: .state}' \
        2>/dev/null || echo '{}')"

    if [[ -z "$PR_DATA" || "$PR_DATA" == "{}" || "$PR_DATA" == "null" ]]; then
        # No closed PR found — skip (might be a live feature branch)
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    PR_NUM=$(echo "$PR_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('number') or 'null')" 2>/dev/null || echo null)
    [[ "$PR_NUM" == "null" ]] && { SKIPPED=$((SKIPPED+1)); continue; }

    # Use merged_at if available, otherwise closed_at
    CLOSED_AT=$(echo "$PR_DATA" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('merged_at') or d.get('closed_at') or 'null')
" 2>/dev/null || echo null)

    [[ "$CLOSED_AT" == "null" || -z "$CLOSED_AT" ]] && { SKIPPED=$((SKIPPED+1)); continue; }

    # Convert to epoch for age comparison
    CLOSED_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$CLOSED_AT" +%s 2>/dev/null || \
                   date -d "$CLOSED_AT" +%s 2>/dev/null || echo 0)
    [[ "$CLOSED_EPOCH" -eq 0 ]] && { SKIPPED=$((SKIPPED+1)); continue; }

    # ── Age check ─────────────────────────────────────────────────────────────
    if [[ "$CLOSED_EPOCH" -gt "$CUTOFF_EPOCH" ]]; then
        # Closed too recently — wait for full aging period
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    AGE_DAYS=$(( ($(date -u +%s) - CLOSED_EPOCH) / 86400 ))

    # ── Prune or report ───────────────────────────────────────────────────────
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[branch-reaper]   DRY-RUN: would prune '$branch' (PR #$PR_NUM, closed ${AGE_DAYS}d ago)"
        _emit_pruned "$branch" "$PR_NUM" "$AGE_DAYS" "dry"
        PRUNED=$((PRUNED+1))
    else
        RC=0
        gh api "repos/$REPO/git/refs/heads/$branch" -X DELETE --silent 2>/dev/null || RC=$?
        if [[ "$RC" -eq 0 ]]; then
            echo "[branch-reaper]   Pruned '$branch' (PR #$PR_NUM, closed ${AGE_DAYS}d ago)"
            _emit_pruned "$branch" "$PR_NUM" "$AGE_DAYS" "act"
            PRUNED=$((PRUNED+1))
        else
            echo "[branch-reaper]   WARN: failed to delete '$branch' (rc=$RC)" >&2
        fi
    fi
done <<< "$ALL_BRANCHES"

echo
echo "[branch-reaper] Summary:"
echo "[branch-reaper]   Total branches:  $TOTAL"
echo "[branch-reaper]   Protected:       $PROTECTED"
echo "[branch-reaper]   Skipped:         $SKIPPED"
echo "[branch-reaper]   $( [[ "$DRY_RUN" -eq 1 ]] && echo 'Would prune' || echo 'Pruned' ): $PRUNED"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    echo "[branch-reaper] Run with --act to execute deletions."
fi
