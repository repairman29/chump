#!/usr/bin/env bash
# Close all race-a / race-z test-artifact gaps left by INFRA-513 atomic-picker
# race test. These are fixture gaps with title "race-a" or "race-z" that were
# accidentally written to the real registry when CHUMP_REPO/CHUMP_HOME pointed
# at the main checkout during test runs.
#
# Usage: bash scripts/dev/close-race-test-gaps.sh [--dry-run]
#
# Safe to re-run: gaps already at status=done are skipped by chump gap set.

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

export CHUMP_BINARY_STALENESS_CHECK=0
# test artifacts have no PR — bypass the INFRA-107 closed_pr integrity guard
export CHUMP_BYPASS_CLOSED_PR_GUARD=1

GAPS=$(chump gap list --status open 2>&1 \
  | grep -E '^\[open\] INFRA-[0-9]+ — race-[az] ' \
  | sed 's/^\[open\] INFRA-\([0-9]*\) .*/\1/' \
  || true)

if [[ -z "$GAPS" ]]; then
  echo "[close-race-test-gaps] No open race-a/race-z gaps found. Nothing to do."
  exit 0
fi

COUNT=0
for NUM in $GAPS; do
  ID="INFRA-$NUM"
  TITLE=$(chump gap show "$ID" 2>/dev/null | grep '^  title:' | awk '{print $2}')
  # Double-check title matches ^race-[az]$ before closing
  if [[ ! "$TITLE" =~ ^race-[az]$ ]]; then
    echo "[close-race-test-gaps] SKIP $ID — title='$TITLE' does not match ^race-[az]$"
    continue
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] would close $ID ($TITLE)"
  else
    echo "[close-race-test-gaps] closing $ID ($TITLE)"
    chump gap set "$ID" --status done --notes "test-artifact-cleanup: INFRA-513 atomic-picker race fixture"
  fi
  (( COUNT++ )) || true
done

echo "[close-race-test-gaps] Done. ${COUNT} gap(s) $([ $DRY_RUN -eq 1 ] && echo 'would be closed' || echo 'closed')."
