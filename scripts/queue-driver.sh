#!/usr/bin/env bash
# INFRA-048 — queue driver: refresh the oldest BEHIND PR with auto-merge armed
# so GitHub branch protection's "require up-to-date" doesn't strand the queue.
#
# Background: branch protection requires PRs to be up-to-date with main, but
# auto-merge does not auto-rebase. When PR N lands, every other auto-merge-armed
# PR goes BEHIND and stays there until something pushes them forward. This
# script does that push.
#
# Usage:
#   scripts/queue-driver.sh                 # refresh oldest BEHIND, exit
#   scripts/queue-driver.sh --dry-run       # report what it would do
#   scripts/queue-driver.sh --max N         # refresh up to N PRs (default 1)
#
# Designed to run from .github/workflows/queue-driver.yml on a 5-min cron and
# on push-to-main. Safe to run from a laptop too.
#
# Requires: gh CLI authenticated (GH_TOKEN env in CI; gh auth login locally).

set -euo pipefail

DRY_RUN=0
MAX=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --max) MAX="$2"; shift 2 ;;
    -h|--help) sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "queue-driver: gh CLI not found" >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "queue-driver: jq not found" >&2
  exit 3
fi

# Pull every open PR with auto-merge armed, sorted oldest-first by PR number.
# Filter to BEHIND state — that's the only thing this driver fixes.
candidates=$(gh pr list \
  --state open \
  --limit 50 \
  --json number,mergeStateStatus,autoMergeRequest,isDraft \
  -q '[.[] | select(.isDraft == false) | select(.autoMergeRequest != null) | select(.mergeStateStatus == "BEHIND") | .number] | sort | .[]')

if [[ -z "$candidates" ]]; then
  echo "queue-driver: no BEHIND auto-merge PRs — nothing to do"
  exit 0
fi

count=0
for pr in $candidates; do
  if [[ "$count" -ge "$MAX" ]]; then
    break
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "queue-driver: (dry-run) would refresh PR #$pr"
  else
    echo "queue-driver: refreshing PR #$pr"
    if gh pr update-branch "$pr" 2>&1; then
      echo "queue-driver: ✓ #$pr refreshed"
    else
      echo "queue-driver: ✗ #$pr refresh failed (may have merge conflict — leaving for owner)"
    fi
  fi
  count=$((count + 1))
done

echo "queue-driver: processed $count PR(s)"
