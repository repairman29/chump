#!/usr/bin/env bash
# INFRA-048 — queue driver: refresh the oldest BEHIND PR with auto-merge armed
# so GitHub branch protection's "require up-to-date" doesn't strand the queue.
#
# Background: branch protection requires PRs to be up-to-date with main, but
# auto-merge does not auto-rebase. When PR N lands, every other auto-merge-armed
# PR goes BEHIND and stays there until something pushes them forward. This
# script does that push.
#
# INFRA-056 extension: also auto-resolve DIRTY PRs whose ONLY conflict is
# docs/gaps.yaml (mechanical tail-append collisions are 90% of DIRTY events
# in this repo). Calls scripts/coord/resolve-gaps-conflict.py — refuses if any
# other file conflicts so non-append conflicts still get human attention.
#
# Usage:
#   scripts/coord/queue-driver.sh                 # process oldest BEHIND/DIRTY, exit
#   scripts/coord/queue-driver.sh --dry-run       # report what it would do
#   scripts/coord/queue-driver.sh --max N         # process up to N PRs (default 1)
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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/coord/resolve-gaps-conflict.py"

# Try to auto-resolve a DIRTY PR by rebasing on main and running the gaps.yaml
# conflict resolver. Refuses if any non-gaps file conflicts. Returns 0 on
# successful push, non-zero otherwise (caller should leave PR alone).
resolve_dirty_pr() {
  local pr="$1"
  local branch
  branch=$(gh pr view "$pr" --json headRefName -q .headRefName)
  if [[ -z "$branch" ]]; then
    echo "queue-driver: ✗ #$pr — could not resolve branch name"
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # Shallow checkout — we only need to rebase one branch on top of main.
  if ! git -C "$REPO_ROOT" worktree add --quiet "$tmpdir" "origin/$branch" 2>&1; then
    echo "queue-driver: ✗ #$pr — worktree add failed (branch=$branch)"
    return 1
  fi

  pushd "$tmpdir" >/dev/null

  git fetch origin main --quiet 2>&1 || true
  if git rebase origin/main 2>&1 | grep -q "Successfully rebased"; then
    # Clean rebase — push and we're done.
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "queue-driver: (dry-run) #$pr clean rebase — would force-push"
    else
      git push origin "HEAD:$branch" --force-with-lease 2>&1 | tail -1
      echo "queue-driver: ✓ #$pr clean rebase pushed"
    fi
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 0
  fi

  # Conflicted — check if it's only docs/gaps.yaml.
  local conflicting
  conflicting=$(git diff --name-only --diff-filter=U)
  if [[ "$conflicting" != "docs/gaps.yaml" ]]; then
    echo "queue-driver: ✗ #$pr DIRTY but conflicts in non-gaps files: $(echo "$conflicting" | tr '\n' ' ')"
    git rebase --abort 2>/dev/null || true
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 1
  fi

  if [[ ! -x "$RESOLVER" ]]; then
    echo "queue-driver: ✗ #$pr — resolver script not found at $RESOLVER"
    git rebase --abort 2>/dev/null || true
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 1
  fi

  if ! python3 "$RESOLVER" docs/gaps.yaml; then
    echo "queue-driver: ✗ #$pr — resolver refused (real content overlap)"
    git rebase --abort 2>/dev/null || true
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 1
  fi

  git add docs/gaps.yaml
  if ! git rebase --continue 2>&1 | tail -3; then
    echo "queue-driver: ✗ #$pr — rebase --continue failed"
    git rebase --abort 2>/dev/null || true
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "queue-driver: (dry-run) #$pr gaps.yaml resolved — would force-push"
  else
    git push origin "HEAD:$branch" --force-with-lease 2>&1 | tail -1
    echo "queue-driver: ✓ #$pr DIRTY auto-resolved (gaps.yaml only)"
  fi

  popd >/dev/null
  git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
  return 0
}

# Pull every open PR with auto-merge armed, sorted oldest-first by PR number.
# Process BEHIND (cheap update-branch) and DIRTY (heavier rebase) — both block
# the queue and both are fixable from the action runner.
behind_candidates=$(gh pr list \
  --state open \
  --limit 50 \
  --json number,mergeStateStatus,autoMergeRequest,isDraft \
  -q '[.[] | select(.isDraft == false) | select(.autoMergeRequest != null) | select(.mergeStateStatus == "BEHIND") | .number] | sort | .[]')

dirty_candidates=$(gh pr list \
  --state open \
  --limit 50 \
  --json number,mergeStateStatus,autoMergeRequest,isDraft \
  -q '[.[] | select(.isDraft == false) | select(.autoMergeRequest != null) | select(.mergeStateStatus == "DIRTY") | .number] | sort | .[]')

if [[ -z "$behind_candidates" && -z "$dirty_candidates" ]]; then
  echo "queue-driver: no BEHIND or DIRTY auto-merge PRs — nothing to do"
  exit 0
fi

count=0

# BEHIND first (cheap, common case).
for pr in $behind_candidates; do
  if [[ "$count" -ge "$MAX" ]]; then
    break
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "queue-driver: (dry-run) would refresh PR #$pr (BEHIND)"
  else
    echo "queue-driver: refreshing PR #$pr (BEHIND)"
    if gh pr update-branch "$pr" 2>&1; then
      echo "queue-driver: ✓ #$pr refreshed"
    else
      echo "queue-driver: ✗ #$pr refresh failed (may have just turned DIRTY — try next run)"
    fi
  fi
  count=$((count + 1))
done

# DIRTY second (rebase + auto-resolve gaps.yaml only).
for pr in $dirty_candidates; do
  if [[ "$count" -ge "$MAX" ]]; then
    break
  fi
  echo "queue-driver: attempting DIRTY auto-resolve for PR #$pr"
  if resolve_dirty_pr "$pr"; then
    : # success message printed by resolver
  else
    echo "queue-driver: leaving #$pr for human owner"
  fi
  count=$((count + 1))
done

echo "queue-driver: processed $count PR(s)"
