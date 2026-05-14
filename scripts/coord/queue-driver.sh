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

# INFRA-999: API cost telemetry. CHUMP_GH_SCRIPT sets the script tag in
# the emitted ambient.jsonl `github_api_call` lines.
# shellcheck source=lib/github.sh
source "$(dirname "$0")/lib/github.sh"
export CHUMP_GH_SCRIPT="queue-driver.sh"

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

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/coord/resolve-gaps-conflict.py"

# INFRA-670/INFRA-711: files whose change in a merged commit requires ALL open
# PRs to be rebased immediately, not just the next-in-queue one. Includes
# workspace config (Cargo.toml, rust-toolchain.toml) and high-traffic shared code
# (src/main.rs, src/lib.rs, src/agent_loop/**, src/dispatch.rs). Invalidates
# every branch's build state, which causes DIRTY conflicts if left unattended.
# Additional paths are configurable via scripts/coord/cascade-rebase-trigger-paths.txt
WORKSPACE_HOT_FILES=(
    "Cargo.toml"
    "rust-toolchain.toml"
)

_cascade_config="$REPO_ROOT/scripts/coord/cascade-rebase-trigger-paths.txt"
if [[ -f "$_cascade_config" ]]; then
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip paths that are already hardcoded
        [[ "$line" == "Cargo.toml" || "$line" == "rust-toolchain.toml" ]] && continue
        WORKSPACE_HOT_FILES+=("$line")
    done < "$_cascade_config"
fi

# Detect whether the most recent commit on main touched any WORKSPACE_HOT_FILES.
# If it did, call `gh pr update-branch` on every open non-draft PR and emit an
# ambient event. Returns 0 always (errors per-PR are soft).
cascade_rebase_if_hot() {
    local changed
    changed=$(git -C "$REPO_ROOT" diff HEAD~1..HEAD --name-only 2>/dev/null || true)
    [[ -z "$changed" ]] && return 0

    local triggered_by=""
    for hot in "${WORKSPACE_HOT_FILES[@]}"; do
        if echo "$changed" | grep -qx "$hot"; then
            triggered_by="$hot"
            break
        fi
    done
    [[ -z "$triggered_by" ]] && return 0

    echo "queue-driver: workspace hot-file '$triggered_by' changed on main — cascade rebasing all open PRs"

    local all_prs
    all_prs=$(chump_gh pr list \
        --state open \
        --limit 100 \
        --json number,isDraft \
        -q '[.[] | select(.isDraft == false) | .number] | sort | .[]')

    if [[ -z "$all_prs" ]]; then
        echo "queue-driver: cascade — no open non-draft PRs to rebase"
        return 0
    fi

    local ok=0 fail=0
    for pr in $all_prs; do
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "queue-driver: (dry-run) cascade would rebase PR #$pr"
            ok=$((ok + 1))
        else
            if chump_gh pr update-branch "$pr" 2>&1; then
                echo "queue-driver: ✓ cascade rebased PR #$pr"
                ok=$((ok + 1))
            else
                echo "queue-driver: ✗ cascade rebase failed for PR #$pr (may already be up-to-date or DIRTY)"
                fail=$((fail + 1))
            fi
        fi
    done

    local ambient="$REPO_ROOT/.chump-locks/ambient.jsonl"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"cascade_rebase_triggered","triggered_by":"%s","pr_ok":%d,"pr_fail":%d,"dry_run":%d}\n' \
        "$now" "$triggered_by" "$ok" "$fail" "$DRY_RUN" \
        >> "$ambient" 2>/dev/null || true

    echo "queue-driver: cascade done — $ok rebased, $fail failed"
}

# INFRA-1137: Auto-resolve a DIRTY PR by rebasing on main + leveraging the
# configured merge drivers in .gitattributes (chump-state-sql-regen,
# ci-yml-add-row, pre-commit-add-guard, gap-yaml-add-line, union). Accept the
# rebase if EVERY remaining conflict is in a merge-driver-configured file
# (the driver tried to resolve, and even if it produced markers, we trust
# `union`/the-driver's-state on the file). Refuse otherwise.
#
# Previously this function only accepted conflicts in the (now-defunct)
# docs/gaps.yaml legacy file — that left ~6 PRs/day stuck DIRTY for hours.
# Returns 0 on successful push, non-zero otherwise.
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
      git fetch origin "$branch" --quiet 2>/dev/null || true
      local _push_out
      _push_out=$(git push origin "HEAD:$branch" --force-with-lease 2>&1)
      local _push_rc=$?
      echo "$_push_out" | tail -1
      if [[ $_push_rc -ne 0 ]]; then
        echo "queue-driver: ✗ #$pr push failed after clean rebase"
        printf '{"ts":"%s","kind":"dirty_pr_push_failed","pr":%s,"phase":"clean_rebase","error":"%s"}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "$(echo "$_push_out" | tail -1 | sed 's/"/\\"/g')" \
          >> "${LOCK_DIR:-$REPO_ROOT/.chump-locks}/ambient.jsonl" 2>/dev/null || true
        popd >/dev/null
        git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
        return 1
      fi
      echo "queue-driver: ✓ #$pr clean rebase pushed"
    fi
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 0
  fi

  # Conflicted — read .gitattributes for files with configured merge drivers.
  # Any conflicting file in this set is auto-resolvable; anything else is
  # genuine human-attention conflict.
  local md_patterns=()
  if [[ -f .gitattributes ]]; then
    # Each line: `<pattern> merge=<driver>` or `<pattern> merge=union`
    while IFS= read -r line; do
      local pat="${line%% *}"
      [[ -n "$pat" && "$pat" != "#"* ]] && md_patterns+=("$pat")
    done < <(grep -E "merge=" .gitattributes 2>/dev/null)
  fi

  local _amb="${LOCK_DIR:-$REPO_ROOT/.chump-locks}/ambient.jsonl"
  local conflicting
  conflicting=$(git diff --name-only --diff-filter=U)
  local conflict_files; conflict_files=$(echo "$conflicting" | tr '\n' ' ')

  # Helper: does a file match any merge-driver pattern?
  _is_md_file() {
    local f="$1" pat
    for pat in "${md_patterns[@]}"; do
      # bash extglob substring match — patterns are filenames or globs.
      # Use bash's [[ var == glob ]] which handles wildcards.
      [[ "$f" == $pat ]] && return 0
    done
    return 1
  }

  # Check every conflicting file is merge-driver-managed.
  local unresolvable=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! _is_md_file "$f"; then
      unresolvable+="$f "
    fi
  done <<< "$conflicting"

  if [[ -n "$unresolvable" ]]; then
    echo "queue-driver: ✗ #$pr DIRTY but conflicts in non-merge-driver files: $unresolvable"
    printf '{"ts":"%s","kind":"dirty_pr_unresolvable","pr":%s,"conflict_files":"%s","unresolvable":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "${conflict_files% }" "${unresolvable% }" \
      >> "$_amb" 2>/dev/null || true
    git rebase --abort 2>/dev/null || true
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 1
  fi

  # Every conflict is in a merge-driver-managed file. The driver should have
  # run already during rebase — re-stage each file (in case the driver wrote
  # a resolved version but didn't clear the conflict flag) and try to continue.
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    git add "$f" 2>/dev/null || true
  done <<< "$conflicting"

  if ! git -c core.editor=true rebase --continue 2>&1 | tail -3; then
    echo "queue-driver: ✗ #$pr — rebase --continue failed after merge-driver resolution"
    printf '{"ts":"%s","kind":"dirty_pr_unresolvable","pr":%s,"conflict_files":"%s","note":"rebase_continue_failed"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "${conflict_files% }" \
      >> "$_amb" 2>/dev/null || true
    git rebase --abort 2>/dev/null || true
    popd >/dev/null
    git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "queue-driver: (dry-run) #$pr DIRTY auto-resolved via merge drivers — would force-push ($conflict_files)"
  else
    git fetch origin "$branch" --quiet 2>/dev/null || true
    local _push_out
    _push_out=$(git push origin "HEAD:$branch" --force-with-lease 2>&1)
    local _push_rc=$?
    echo "$_push_out" | tail -1
    if [[ $_push_rc -ne 0 ]]; then
      echo "queue-driver: ✗ #$pr push failed after dirty auto-resolve"
      printf '{"ts":"%s","kind":"dirty_pr_push_failed","pr":%s,"conflict_files":"%s","phase":"dirty_resolve","error":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "${conflict_files% }" "$(echo "$_push_out" | tail -1 | sed 's/"/\\"/g')" \
        >> "$_amb" 2>/dev/null || true
      git rebase --abort 2>/dev/null || true
      popd >/dev/null
      git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
      return 1
    fi
    echo "queue-driver: ✓ #$pr DIRTY auto-resolved via merge drivers ($conflict_files)"
    printf '{"ts":"%s","kind":"dirty_pr_auto_resolved","pr":%s,"conflict_files":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pr" "${conflict_files% }" \
      >> "$_amb" 2>/dev/null || true
  fi

  popd >/dev/null
  git -C "$REPO_ROOT" worktree remove --force "$tmpdir" 2>/dev/null || true
  return 0
}

# INFRA-670: cascade rebase when a workspace-wide file (Cargo.toml, etc.) just
# landed on main. Must run before the BEHIND/DIRTY loop so we don't miss PRs
# that don't have auto-merge armed but still need rebasing.
cascade_rebase_if_hot

# INFRA-1081: prefer reading BEHIND PRs from .chump/github_cache.db (populated
# by github-webhook-receiver.py + reconcile). Avoids burning GraphQL on every
# 5-min cron tick. Falls back to direct gh pr list when cache is empty (first
# run, after cache nuke, or smee/webhook receiver down).
behind_candidates=""
dirty_candidates=""
if [[ -f "$(dirname "$0")/lib/github_cache.sh" ]]; then
    # shellcheck source=lib/github_cache.sh
    source "$(dirname "$0")/lib/github_cache.sh"
    behind_candidates="$(cache_query_behind_prs)"
    # DIRTY rows are also in the cache — same shape, different mergeable_state.
    dirty_candidates="$(sqlite3 "$(_cache_db_path)" \
        "SELECT number FROM pr_state \
         WHERE mergeable_state='DIRTY' AND auto_merge_enabled=1 AND merged_at IS NULL \
         ORDER BY number ASC" 2>/dev/null || true)"
fi
# Fallback: cache empty (or library missing) → one direct gh pr list call.
if [[ -z "$behind_candidates" && -z "$dirty_candidates" ]]; then
    behind_candidates=$(chump_gh pr list \
      --state open \
      --limit 50 \
      --json number,mergeStateStatus,autoMergeRequest,isDraft \
      -q '[.[] | select(.isDraft == false) | select(.autoMergeRequest != null) | select(.mergeStateStatus == "BEHIND") | .number] | sort | .[]')

    dirty_candidates=$(chump_gh pr list \
      --state open \
      --limit 50 \
      --json number,mergeStateStatus,autoMergeRequest,isDraft \
      -q '[.[] | select(.isDraft == false) | select(.autoMergeRequest != null) | select(.mergeStateStatus == "DIRTY") | .number] | sort | .[]')
fi

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
    if chump_gh pr update-branch "$pr" 2>&1; then
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
