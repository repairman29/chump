#!/usr/bin/env bash
# scripts/ops/ghost-open-gaps-reaper.sh — INFRA-359
#
# Close ghost-open gaps: state.db says status=open AND a merged PR on
# origin/main has the gap-ID in title. Caused by manual ship paths
# (CLAUDE.md INFRA-028 recovery) bypassing bot-merge.sh's INFRA-154
# auto-close, leaving 20+ gaps in state.db as "open" even though the
# implementation already landed.
#
# Effect: every fleet worker on every cycle re-picks these phantom-open
# gaps, spends a worktree-create + cargo cycle, then claude-p exits
# rc=1 because the work is done. Worker 4 was observed re-attempting
# INFRA-340 six times in a few minutes (2026-05-03).
#
# Strategy: for each open gap, search merged PRs by title; if any
# merged PR has the gap-ID in its title, close the gap (set status=done,
# closed_pr=N, closed_date=YYYY-MM-DD). Idempotent — already-done gaps
# are skipped.
#
# State.db is gitignored — runs LOCALLY on each operator machine.
# Recommended cron: every 30 min via launchd (pairs with INFRA-308 cron).
#
# Usage:
#   bash scripts/ops/ghost-open-gaps-reaper.sh             # apply
#   bash scripts/ops/ghost-open-gaps-reaper.sh --dry-run   # report only
#   bash scripts/ops/ghost-open-gaps-reaper.sh --limit 5   # cap (debug)
#
# Pairs with: gap-doctor-backfill-closed-pr.sh (INFRA-319 — closed_pr
# backfill for gaps already status=done). This script handles the OTHER
# direction: gaps that are status=open but should be done.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"

DRY=0
LIMIT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --limit)   LIMIT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -f "$DB" ]] || { echo "ERROR: state.db missing at $DB" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI required" >&2; exit 2; }
command -v chump >/dev/null 2>&1 || { echo "ERROR: chump binary required" >&2; exit 2; }

QUERY="SELECT id FROM gaps WHERE status='open' ORDER BY id"
[[ "$LIMIT" -gt 0 ]] && QUERY="$QUERY LIMIT $LIMIT"

GAPS="$(sqlite3 "$DB" "$QUERY;")"
TOTAL="$(printf '%s\n' "$GAPS" | grep -c .)"

if [[ "$TOTAL" -eq 0 ]]; then
    echo "[ghost-reaper] no open gaps — nothing to do"
    exit 0
fi

echo "[ghost-reaper] scanning $TOTAL open gaps for merged PRs"
[[ "$DRY" -eq 1 ]] && echo "[ghost-reaper] DRY-RUN — no writes"

closed=0
not_found=0
errors=0

while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue
    # gh pr list with title-anchored search; require title PREFIX match
    # so "INFRA-30" doesn't pick up "INFRA-300", "INFRA-301", etc.
    pr_data="$(gh pr list --state merged --search "$gap in:title" --json number,title,mergedAt \
        -q ".[] | select(.title | startswith(\"$gap:\") or startswith(\"$gap \") or startswith(\"$gap (\")) | \"\\(.number) \\(.mergedAt[:10])\"" 2>/dev/null \
        | head -1 || true)"
    if [[ -z "$pr_data" ]]; then
        not_found=$((not_found + 1))
        continue
    fi
    pr_num="${pr_data%% *}"
    pr_date="${pr_data##* }"
    if [[ "$DRY" -eq 1 ]]; then
        echo "  $gap  → would close (PR #$pr_num, merged $pr_date)"
        closed=$((closed + 1))
        continue
    fi
    if chump gap set "$gap" --status done --closed-pr "$pr_num" --closed-date "$pr_date" >/dev/null 2>&1; then
        closed=$((closed + 1))
        [[ $((closed % 5)) -eq 0 ]] && echo "  ...closed $closed so far"
    else
        errors=$((errors + 1))
        echo "  WARN $gap: chump gap set failed" >&2
    fi
done <<< "$GAPS"

echo
echo "[ghost-reaper] summary:"
echo "  scanned     : $TOTAL"
echo "  closed      : $closed"
echo "  no-match    : $not_found  (truly open — no merged PR with this gap-ID)"
echo "  errors      : $errors"
[[ "$DRY" -eq 1 ]] && echo "  (dry-run — no writes applied)"
