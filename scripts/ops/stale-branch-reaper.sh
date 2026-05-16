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
#   4. Skips branches with NO associated PR (safety: could be active WIP).
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
BRANCH_PATTERNS="${BRANCH_PATTERNS:-claude/* worktree-*}"
# INFRA-697: age threshold for merged/closed PR branches (days since close).
CHUMP_BRANCH_REAPER_AGE_DAYS="${CHUMP_BRANCH_REAPER_AGE_DAYS:-7}"

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

# Branches with an open PR are safe regardless of age.
OPEN_PR_BRANCHES=$(gh pr list --state open --json headRefName \
    --jq '.[].headRefName' 2>/dev/null | sort -u || true)

# INFRA-697: Fetch closed (merged + closed-without-merge) PRs with their
# close/merge timestamp. Format per line: "branch|ISO8601timestamp"
# We fetch up to 500 so we cover the typical claude/* branch history.
CLOSED_PR_LIST=$(gh pr list --state closed --limit 500 \
    --json headRefName,mergedAt,closedAt \
    --jq '.[] | .headRefName + "|" + (if .mergedAt != null and .mergedAt != "" then .mergedAt else .closedAt end)' \
    2>/dev/null || true)

NOW_EPOCH=$(date +%s)
THRESHOLD_SECS=$(( STALE_DAYS_THRESHOLD * 86400 ))
PR_AGE_THRESHOLD_SECS=$(( CHUMP_BRANCH_REAPER_AGE_DAYS * 86400 ))

REAPED=0
SKIPPED_PR=0
SKIPPED_FRESH=0
SKIPPED_NO_PR=0

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
    if [[ -z "$closed_pr_line" ]]; then
        SKIPPED_NO_PR=$((SKIPPED_NO_PR + 1))
        continue
    fi

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

    pr_age_secs=$(( NOW_EPOCH - close_epoch ))
    if [[ "$pr_age_secs" -lt "$PR_AGE_THRESHOLD_SECS" ]]; then
        pr_age_days=$(( pr_age_secs / 86400 ))
        info "Fresh: $BRANCH (PR closed/merged ${pr_age_days}d ago, threshold ${CHUMP_BRANCH_REAPER_AGE_DAYS}d)"
        SKIPPED_FRESH=$((SKIPPED_FRESH + 1))
        continue
    fi

    pr_age_days=$(( pr_age_secs / 86400 ))
    info "Stale: $BRANCH (PR closed/merged ${pr_age_days}d ago)"

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
green "=== reaper done: $REAPED reaped, $SKIPPED_PR skipped (open PR), $SKIPPED_NO_PR skipped (no PR), $SKIPPED_FRESH skipped (fresh) ==="

# INFRA-120: emit heartbeat + reaper_run event so the watchdog and other
# agents can see this reaper completed.
trap - EXIT
reaper_finish ok "{\"reaped\":$REAPED,\"skipped_pr\":$SKIPPED_PR,\"skipped_no_pr\":$SKIPPED_NO_PR,\"skipped_fresh\":$SKIPPED_FRESH,\"execute\":$EXECUTE}"
