#!/usr/bin/env bash
# scripts/ops/audit-stale-worktrees.sh — ZERO-WASTE-001
#
# READ-ONLY audit of stale worktrees. Surfaces worktrees that look
# abandoned BEFORE the reaper threshold trips so an operator can decide
# what to do (rescue WIP vs let the reaper sweep).
#
# Companion to (but distinct from):
#   - scripts/coord/worktree-prune.sh        (INFRA-1347 — actual pruning)
#   - scripts/ops/stale-worktree-reaper.sh   (INFRA-1074 — auto-reaping)
#   - scripts/ops/prune-worktrees.sh         (RESILIENT-013 — orphan mode)
#
# This script NEVER deletes anything. It emits ambient events and prints
# a human-readable table. Per ZERO-WASTE-001 AC #6, there is no
# `--execute` flag — pruning belongs to the scripts above.
#
# Detection taxonomy (the `reason` field on each emitted event):
#   - orphaned_lease         lease exists for this worktree but heartbeat
#                            is older than 24h (lease holder went silent)
#   - no_lease_ever_existed  no lease in .chump-locks/ names this worktree
#                            AND the worktree directory is older than 24h
#
# Scan dirs: <repo>/.claude/worktrees/* + /private/tmp/chump-* (via
# scripts/lib/worktree-iter.sh::scan_worktrees).
#
# Usage:
#   scripts/ops/audit-stale-worktrees.sh                     # human table to stdout
#   scripts/ops/audit-stale-worktrees.sh --json              # one JSON obj per line
#   scripts/ops/audit-stale-worktrees.sh --age-hours 12      # custom staleness threshold
#   scripts/ops/audit-stale-worktrees.sh --scan-dir <path>   # override scan root (testing)
#   scripts/ops/audit-stale-worktrees.sh --quiet             # suppress table, only events
#
# Exit codes:
#   0  audit ran cleanly (stale or not)
#   2  bad CLI args

set -euo pipefail

AGE_HOURS=24
FORMAT=table             # table | json
QUIET=0
EXTRA_SCAN_DIR=""        # for tests — overrides default scan dirs entirely

while [[ $# -gt 0 ]]; do
    case "$1" in
        --age-hours)   AGE_HOURS="$2"; shift 2 ;;
        --json)        FORMAT=json; shift ;;
        --quiet)       QUIET=1; shift ;;
        --scan-dir)    EXTRA_SCAN_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Validate age_hours is a positive integer.
if ! [[ "$AGE_HOURS" =~ ^[0-9]+$ ]] || [[ "$AGE_HOURS" -lt 1 ]]; then
    echo "error: --age-hours must be a positive integer (got: $AGE_HOURS)" >&2
    exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MAIN_REPO="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2; exit}')"
[[ -z "$MAIN_REPO" ]] && MAIN_REPO="$REPO_ROOT"

# Resolve the directory holding this script so we always source the libs
# next to us — not from whatever cwd the caller invoked us in. This matters
# for test environments that run the script against a synthetic fake-repo.
SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_SELF_DIR/../lib"

# Shared libs (do NOT modify these — sibling-lease).
# shellcheck source=scripts/lib/lease.sh
# shellcheck disable=SC1091
source "$LIB_DIR/lease.sh"
# shellcheck source=scripts/lib/worktree-iter.sh
# shellcheck disable=SC1091
source "$LIB_DIR/worktree-iter.sh"

REAPER_NAME="audit-stale-worktrees"
REAPER_REPO_ROOT="$MAIN_REPO"
export REAPER_NAME REAPER_REPO_ROOT

AGE_SECONDS=$(( AGE_HOURS * 3600 ))
NOW_EPOCH="$(date -u +%s)"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Return the mtime epoch of the worktree path. Falls back to ctime if mtime
# missing. macOS `stat -f %m` / Linux `stat -c %Y`.
_wt_mtime_epoch() {
    local p="$1"
    stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null || echo 0
}

# Echo "lease_path" (first match) for a worktree, or empty if none.
# Matches either /tmp/X or /private/tmp/X on macOS.
_find_lease_for_wt() {
    local wt="$1"
    local wt_alt=""
    if [[ "$wt" == /tmp/* ]]; then
        wt_alt="/private${wt}"
    elif [[ "$wt" == /private/tmp/* ]]; then
        wt_alt="${wt#/private}"
    fi
    local lease claimed
    while IFS= read -r lease; do
        [[ -f "$lease" ]] || continue
        claimed="$(lease_worktree "$lease" 2>/dev/null || true)"
        [[ -z "$claimed" ]] && continue
        if [[ "$claimed" == "$wt" || "$claimed" == "$wt_alt" ]]; then
            printf '%s\n' "$lease"
            return 0
        fi
    done < <(lease_iter --repo "$MAIN_REPO")
    return 0
}

# Print one row in table format.
_print_table_row() {
    local wt="$1" age_h="$2" reason="$3" branch="$4" lease="$5"
    printf "  %-45s %6sh  %-22s %-30s %s\n" \
        "$wt" "$age_h" "$reason" "$branch" "$lease"
}

# Print one row in JSON format (one object per line).
_print_json_row() {
    local wt="$1" age_h="$2" reason="$3" branch="$4" lease="$5"
    printf '{"path":"%s","age_hours":%s,"reason":"%s","branch":"%s","lease":"%s"}\n' \
        "$wt" "$age_h" "$reason" "$branch" "$lease"
}

# Get the branch of a worktree (or "?" if not a git worktree).
_wt_branch() {
    local wt="$1"
    (env -u GIT_DIR -u GIT_WORK_TREE git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) \
        || echo "?"
}

# ── Header ──────────────────────────────────────────────────────────────────

if [[ "$FORMAT" == "table" && "$QUIET" -eq 0 ]]; then
    echo "[audit-stale-worktrees] READ-ONLY audit (no pruning; INFRA-1347 handles that)"
    echo "[audit-stale-worktrees] staleness threshold: ${AGE_HOURS}h"
    echo
    printf "  %-45s %7s  %-22s %-30s %s\n" \
        "WORKTREE" "AGE" "REASON" "BRANCH" "LEASE"
    printf "  %-45s %7s  %-22s %-30s %s\n" \
        "--------" "---" "------" "------" "-----"
fi

# ── Scan ─────────────────────────────────────────────────────────────────────

stale_orphan_lease=0
stale_no_lease=0
total_scanned=0

# Build the candidate list. If --scan-dir was passed (test mode), use ONLY that
# directory's subdirs. Otherwise scan canonical roots via scan_worktrees().
_emit_candidates() {
    if [[ -n "$EXTRA_SCAN_DIR" ]]; then
        if [[ -d "$EXTRA_SCAN_DIR" ]]; then
            for d in "$EXTRA_SCAN_DIR"/*/; do
                [[ -d "$d" ]] && printf '%s\n' "${d%/}"
            done
        fi
    else
        scan_worktrees --repo "$MAIN_REPO"
    fi
}

while IFS= read -r wt; do
    [[ -n "$wt" && -d "$wt" ]] || continue
    total_scanned=$(( total_scanned + 1 ))

    mtime="$(_wt_mtime_epoch "$wt")"
    [[ "$mtime" -gt 0 ]] || continue
    age_s=$(( NOW_EPOCH - mtime ))
    age_h=$(( age_s / 3600 ))

    # Skip fresh worktrees outright.
    if [[ "$age_s" -lt "$AGE_SECONDS" ]]; then
        continue
    fi

    lease="$(_find_lease_for_wt "$wt")"
    branch="$(_wt_branch "$wt")"

    if [[ -n "$lease" ]]; then
        # Lease exists — check whether heartbeat is still fresh. If fresh,
        # this isn't stale (active worker). If old, orphaned_lease.
        if lease_is_fresh "$lease" "$AGE_SECONDS"; then
            continue
        fi
        reason="orphaned_lease"
        stale_orphan_lease=$(( stale_orphan_lease + 1 ))
    else
        reason="no_lease_ever_existed"
        stale_no_lease=$(( stale_no_lease + 1 ))
    fi

    # Emit ambient event (always — this is the machine-readable surface).
    emit_reaper_event "worktree_stale_detected" "$wt" "$reason" \
        "\"age_hours\":$age_h,\"branch\":\"$branch\",\"lease\":\"${lease:-}\""

    # Print row (skip if --quiet).
    if [[ "$QUIET" -eq 0 ]]; then
        if [[ "$FORMAT" == "json" ]]; then
            _print_json_row "$wt" "$age_h" "$reason" "$branch" "${lease:-}"
        else
            _print_table_row "$wt" "$age_h" "$reason" "$branch" "${lease:-(none)}"
        fi
    fi
done < <(_emit_candidates)

# ── Summary ──────────────────────────────────────────────────────────────────

if [[ "$FORMAT" == "table" && "$QUIET" -eq 0 ]]; then
    echo
    echo "── summary ──"
    echo "  scanned:                $total_scanned worktree(s)"
    echo "  stale (orphaned lease): $stale_orphan_lease"
    echo "  stale (no lease ever):  $stale_no_lease"
    echo
    echo "  This audit is READ-ONLY. To actually prune, see:"
    echo "    scripts/coord/worktree-prune.sh --execute       (INFRA-1347)"
    echo "    scripts/ops/prune-worktrees.sh                  (RESILIENT-013)"
fi

exit 0
