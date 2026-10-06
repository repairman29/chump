#!/usr/bin/env bash
# stale-branch-reaper.sh — Auto-delete remote branches with merged/closed PRs.
#
# Sister to stale-pr-reaper.sh (which closes stale PRs whose gaps landed on
# main). This one closes the *other* leak: branches whose PR is MERGED or
# CLOSED and are now stale.
#
# INFRA-697: extended to detect branches with MERGED or CLOSED PRs that are
# older than CHUMP_BRANCH_REAPER_AGE_DAYS (default 7d). Safety: only deletes
# branches that have an associated PR — branches without any PR are skipped
# (might be WIP pushed without opening a PR).
#
# What it does:
#   1. Lists all remote branches matching configured patterns.
#   2. Skips branches with an OPEN PR (still in flight).
#   3. For branches with a MERGED or CLOSED PR: deletes if the PR was
#      merged/closed > CHUMP_BRANCH_REAPER_AGE_DAYS ago.
#   4. RESILIENT-1545: also deletes branches whose gap-ID (from the branch
#      name) appears in a landed commit subject on main (squash-safe), once
#      the branch tip is older than the age threshold.
#   5. Skips branches with NO PR whose gap-ID has not shipped (safety: could be
#      active WIP) and FLAGS them for review; never deletes them.
#
# Usage:
#   ./scripts/ops/stale-branch-reaper.sh             # dry-run by default
#   ./scripts/ops/stale-branch-reaper.sh --execute   # actually delete refs
#
# Environment:
#   REMOTE                       git remote (default: origin)
#   BASE                         protected base — never deleted (default: main)
#   CHUMP_BRANCH_REAPER_AGE_DAYS days since PR merged/closed before reap
#                                (default: 7)
#   STALE_DAYS_THRESHOLD         legacy: days since last commit (default: 14,
#                                unused for branches with a PR)
#   BRANCH_PATTERNS              space-separated git-ref globs to consider
#                                (default: "claude/* worktree-*")

set -euo pipefail

# RESILIENT-1545: the repo SQUASH-merges via a batched merge-train, so a merged
# branch's commits are never reachable from main and never match its patch-ids
# (git branch --merged / rev-list / cherry all under-count). The squash-safe
# signal is the gap-ID: every branch name encodes one (claude/infra-2360,
# chump/resilient-1002-*) and every landed squash subject leads with one.
# branch_gap_id <branch>  -> "INFRA-2360" (empty if the name encodes none)
branch_gap_id() {
    local base="${1##*/}"
    if [[ "$base" =~ ^([A-Za-z][A-Za-z0-9]*)-([0-9]+)($|[-_.]) ]]; then
        printf '%s-%s\n' "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')" "${BASH_REMATCH[2]}"
    fi
}
# shipped_gap_ids <ref>  -> sorted unique gap-IDs leading commit subjects on <ref>
shipped_gap_ids() {
    git log "$1" --format=%s 2>/dev/null \
        | sed -nE 's/^[[:space:]]*([A-Za-z][A-Za-z0-9]*-[0-9]+)[^0-9A-Za-z].*/\1/p; s/^[[:space:]]*([A-Za-z][A-Za-z0-9]*-[0-9]+)$/\1/p' \
        | tr '[:lower:]' '[:upper:]' | sort -u
}
# Test hook: source just the helpers above.
[[ "${REAPER_SOURCE_ONLY:-}" == "1" ]] && return 0

# INFRA-120: shared instrumentation (heartbeat + ambient reaper_run event +
# log rotation). Watchdog reads /tmp/chump-reaper-branch.heartbeat.
# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup branch
reaper_check_disk_headroom  # INFRA-453: exit 0 + ALERT if <5% free
reaper_rotate_log /tmp/chump-stale-branch-reaper.out.log
reaper_rotate_log /tmp/chump-stale-branch-reaper.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

EXECUTE=0
[[ "${1:-}" == "--execute" ]] && EXECUTE=1

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
STALE_DAYS_THRESHOLD="${STALE_DAYS_THRESHOLD:-14}"
# ZERO-WASTE-037: the default MUST track the fleet's live branch namespaces, or
# the reaper goes blind. The fleet migrated claude/* -> chump/* and now pushes the
# bulk of work under wip/*; the old `claude/* worktree-*` default matched only ~5
# of 674 accumulated refs (every run logged "0 reaped, N skipped (no PR)" over a
# handful of branches). Deletion stays gated downstream by the merged/closed-PR +
# age + open-PR + protected-branch checks, so widening what is *examined* is safe;
# it never widens what is *deleted*. Keep this list in sync with `git ls-remote
# --heads origin | sed 's#.*/##' | ...` prefixes when new namespaces appear.
BRANCH_PATTERNS="${BRANCH_PATTERNS:-chump/* wip/* claude/* worktree-* chore/* fix/* ftue-verification/* test/*}"
# INFRA-697: age threshold for merged/closed PR branches (days since close).
CHUMP_BRANCH_REAPER_AGE_DAYS="${CHUMP_BRANCH_REAPER_AGE_DAYS:-7}"

# INFRA-1081: source github cache lib
# shellcheck source=scripts/coord/lib/github_cache.sh
if [[ -f "$(dirname "$0")/../coord/lib/github_cache.sh" ]]; then
    source "$(dirname "$0")/../coord/lib/github_cache.sh"
fi

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

green "=== stale-branch-reaper (remote: $REMOTE, pr-age threshold: ${CHUMP_BRANCH_REAPER_AGE_DAYS}d) ==="
[[ $EXECUTE -eq 0 ]] && info "Dry-run mode — pass --execute to actually delete refs."

git fetch "$REMOTE" --prune --quiet 2>/dev/null || {
    red "Could not fetch $REMOTE — aborting."; exit 1
}

# Branches with an open PR are safe regardless of age (INFRA-1081: cache-first).
OPEN_PR_BRANCHES=""
if command -v cache_query_open_prs >/dev/null 2>&1; then
    OPEN_PR_BRANCHES=$(cache_query_open_prs | awk -F$'\t' '{print $3}' | sort -u || true)
fi
if [[ -z "$OPEN_PR_BRANCHES" ]]; then
    OPEN_PR_BRANCHES=$(gh pr list --state open --json headRefName \
        --jq '.[].headRefName' 2>/dev/null | sort -u || true)
fi

# INFRA-697: Fetch closed (merged + closed-without-merge) PRs with their
# close/merge timestamp. Format per line: "branch|ISO8601timestamp"
# We fetch up to 500 so we cover the typical claude/* branch history.
CLOSED_PR_LIST=""
if command -v cache_query_closed_prs >/dev/null 2>&1; then
    # cache_query_closed_prs returns number\ttitle\thead_ref\tclosed_at
    CLOSED_PR_LIST=$(cache_query_closed_prs | awk -F$'\t' '{print $3 "|" $4}' || true)
fi

if [[ -z "$CLOSED_PR_LIST" ]]; then
    CLOSED_PR_LIST=$(gh pr list --state closed --limit 500 \
        --json headRefName,mergedAt,closedAt \
        --jq '.[] | .headRefName + "|" + (if .mergedAt != null and .mergedAt != "" then .mergedAt else .closedAt end)' \
        2>/dev/null || true)
fi

# RESILIENT-1545: gap-IDs already landed on main (squash-safe shipped signal).
SHIPPED_IDS="$(shipped_gap_ids "$REMOTE/$BASE" || true)"
info "Shipped gap-IDs on $REMOTE/$BASE: $(printf '%s\n' "$SHIPPED_IDS" | grep -c . || true)"

NOW_EPOCH=$(date +%s)
THRESHOLD_SECS=$(( STALE_DAYS_THRESHOLD * 86400 ))
PR_AGE_THRESHOLD_SECS=$(( CHUMP_BRANCH_REAPER_AGE_DAYS * 86400 ))

REAPED=0
SKIPPED_PR=0
SKIPPED_FRESH=0
SKIPPED_NO_PR=0
SKIPPED_FLAGGED=0

# Build the ref-list pattern args for git for-each-ref.
PATTERN_ARGS=()
for pat in $BRANCH_PATTERNS; do
    PATTERN_ARGS+=("refs/remotes/$REMOTE/$pat")
done

while IFS=$'\t' read -r REFNAME COMMITTERDATE; do
    BRANCH="${REFNAME#refs/remotes/$REMOTE/}"

    # Never touch the base.
    if [[ "$BRANCH" == "$BASE" ]]; then continue; fi

    # Skip if there's an open PR for this branch (still in flight).
    if echo "$OPEN_PR_BRANCHES" | grep -qx "$BRANCH"; then
        SKIPPED_PR=$((SKIPPED_PR + 1))
        continue
    fi

    # INFRA-697: check for a closed/merged PR.
    # Safety: branches with NO associated PR are skipped — they might be
    # active WIP pushed before opening a PR.
    closed_pr_line=$(echo "$CLOSED_PR_LIST" | grep -m1 "^${BRANCH}|" 2>/dev/null || true)
    shipped_reason=""
    if [[ -z "$closed_pr_line" ]]; then
        # RESILIENT-1545: no closed/merged PR on record — fall back to the
        # squash-safe gap-ID signal. A shipped gap-ID is reaped once the branch
        # tip is older than the age threshold; anything else is flagged, never
        # deleted (could be the only copy of unique work).
        gid="$(branch_gap_id "$BRANCH")"
        if [[ -n "$gid" ]] && printf '%s\n' "$SHIPPED_IDS" | grep -qxF "$gid"; then
            tip_age=$(( NOW_EPOCH - ${COMMITTERDATE:-0} ))
            if [[ "${COMMITTERDATE:-0}" -gt 0 && "$tip_age" -ge "$PR_AGE_THRESHOLD_SECS" ]]; then
                shipped_reason="gap-id $gid shipped on $BASE"
                close_epoch=$(( COMMITTERDATE ))
            else
                info "Fresh: $BRANCH (gap-id $gid shipped but tip < ${CHUMP_BRANCH_REAPER_AGE_DAYS}d old)"
                SKIPPED_FRESH=$((SKIPPED_FRESH + 1))
                continue
            fi
        else
            SKIPPED_NO_PR=$((SKIPPED_NO_PR + 1))
            SKIPPED_FLAGGED=$((SKIPPED_FLAGGED + 1))
            info "Flag: $BRANCH (no PR, gap-id ${gid:-none} not shipped — keep for review)"
            continue
        fi
    fi

    if [[ -z "$shipped_reason" ]]; then
    # Parse the close/merge timestamp and compute age.
    close_ts="${closed_pr_line#*|}"
    close_epoch=$(python3 -c "
import sys
from datetime import datetime, timezone
ts = sys.argv[1].rstrip('Z')
# Handle both '2026-05-01T12:34:56Z' and '2026-05-01T12:34:56'
try:
    dt = datetime.fromisoformat(ts)
except ValueError:
    dt = datetime.strptime(ts, '%Y-%m-%dT%H:%M:%S')
if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
" "$close_ts" 2>/dev/null || echo "0")

    if [[ "$close_epoch" -le 0 ]]; then
        warn "$BRANCH: could not parse close timestamp ($close_ts) — skipping"
        SKIPPED_FRESH=$((SKIPPED_FRESH + 1))
        continue
    fi
    fi

    pr_age_secs=$(( NOW_EPOCH - close_epoch ))
    if [[ "$pr_age_secs" -lt "$PR_AGE_THRESHOLD_SECS" ]]; then
        pr_age_days=$(( pr_age_secs / 86400 ))
        info "Fresh: $BRANCH (PR closed/merged ${pr_age_days}d ago, threshold ${CHUMP_BRANCH_REAPER_AGE_DAYS}d)"
        SKIPPED_FRESH=$((SKIPPED_FRESH + 1))
        continue
    fi

    pr_age_days=$(( pr_age_secs / 86400 ))
    info "Stale: $BRANCH (${shipped_reason:-PR closed/merged ${pr_age_days}d ago})"

    if [[ $EXECUTE -eq 1 ]]; then
        if git push "$REMOTE" --delete "$BRANCH" 2>/dev/null; then
            green "  Deleted $REMOTE/$BRANCH."
            REAPED=$((REAPED + 1))
            # INFRA-1453: per-deletion emit so operator can audit which branches
            # were reaped without grepping /tmp/chump-stale-branch-reaper.out.log.
            # The reaper_finish summary at the end gives aggregate counts; this
            # event gives the per-branch detail.
            _bt_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"ts":"%s","kind":"branch_reaped","branch":"%s","age_days":%s,"reaper_run_id":"%s"}\n' \
                "$_bt_ts" "$BRANCH" "$pr_age_days" "${REAPER_NAME:-branch}-${REAPER_START_EPOCH:-$(date +%s)}" \
                >> "${REAPER_LOCK_DIR:-$(_reaper_main_repo)/.chump-locks}/ambient.jsonl" 2>/dev/null || true
            unset _bt_ts
        else
            warn "Failed to delete $REMOTE/$BRANCH (protected? already gone?)"
        fi
    else
        dry "git push $REMOTE --delete $BRANCH"
        REAPED=$((REAPED + 1))
    fi
done < <(git for-each-ref --format='%(refname)%09%(committerdate:unix)' \
            "${PATTERN_ARGS[@]}" 2>/dev/null)

echo ""
green "=== reaper done: $REAPED reaped, $SKIPPED_PR skipped (open PR), $SKIPPED_NO_PR skipped (no PR, $SKIPPED_FLAGGED flagged), $SKIPPED_FRESH skipped (fresh) ==="

# INFRA-120: emit heartbeat + reaper_run event so the watchdog and other
# agents can see this reaper completed.
trap - EXIT
reaper_finish ok "{\"reaped\":$REAPED,\"skipped_pr\":$SKIPPED_PR,\"skipped_no_pr\":$SKIPPED_NO_PR,\"skipped_fresh\":$SKIPPED_FRESH,\"execute\":$EXECUTE}"
