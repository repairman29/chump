#!/usr/bin/env bash
# scripts/coord/pr-resolve-or-retire.sh — INFRA-3614
#
# The organ that closes the gap pr-auto-rebase.sh leaves open: it only
# fast-forwards/rebases CLEAN or cleanly-rebaseable branches. A PR whose
# branch has a TRUE conflict (local rebase also fails) is left DIRTY
# forever — no daemon resolves it and no daemon retires it. Receipt
# (2026-08-19): #3919/#3924/#3910 all sat CONFLICTING+stale indefinitely;
# all 3 turned out to be redundant (their diff was already on main) and
# were retired by hand.
#
# For every open PR with mergeStateStatus DIRTY (or CONFLICTING, GitHub's
# REST term for the same condition):
#   1. If the branch's diff vs. main is EMPTY (git diff --stat is empty
#      after a merge-base compare) — the work is already on main. RETIRE:
#      close the PR, delete the branch, stamp closed_pr on the owning gap
#      if one is claimable from the branch name, emit
#      kind=pr_retired_redundant. This is content-based, not
#      commit-based — it does not require the branch to be a literal
#      ancestor of main, only for `git diff main...branch` to be empty.
#   2. Else, attempt a local content-rebase (same fallback pattern as
#      pr-auto-rebase.sh's INFRA-1958 path). Success → push + re-arm.
#   3. Else (true conflict, non-redundant) — this PR needs a human/agent
#      to resolve conflicting hunks; emit kind=pr_conflict_unresolvable
#      with the conflict file list so shepherd can triage. NOT retired —
#      retiring non-redundant work would silently drop it (AC3 boundary).
#
# Usage:
#   bash scripts/coord/pr-resolve-or-retire.sh [--dry-run]
#
# Telemetry:
#   kind=pr_retired_redundant       — closed + branch deleted, diff was empty
#   kind=pr_content_rebased         — true conflict resolved by local rebase, pushed
#   kind=pr_conflict_unresolvable   — true conflict, NOT redundant; needs a human/shepherd
#   kind=pr_resolve_or_retire_skip  — not DIRTY/CONFLICTING, or no branch, etc.
# scanner-anchor: "kind":"pr_retired_redundant"
# scanner-anchor: "kind":"pr_content_rebased"
# scanner-anchor: "kind":"pr_conflict_unresolvable"
# scanner-anchor: "kind":"pr_resolve_or_retire_skip"

set -uo pipefail

DRY_RUN=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT")"

emit() {
    local kind="$1" pr="$2" extra="${3:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"pr\":$pr,$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"pr\":$pr}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

# Given a branch name like chump/infra-3614-fleet-1-... derive the
# canonical GAP-ID (best-effort — same convention pr-rescue-false-close.sh
# uses). Empty output if it doesn't parse.
gap_id_from_branch() {
    local branch="$1"
    echo "$branch" | sed -E 's|^chump/||' | awk -F- '{print toupper($1)"-"$2}'
}

# Is the branch's diff against main empty? (i.e. every line change on the
# branch is already reflected in main — content-redundant, regardless of
# whether the branch is a literal fast-forward ancestor.)
branch_diff_is_empty() {
    local branch="$1"
    local stat
    stat="$(git -C "$REPO_ROOT" diff --stat "origin/main...origin/$branch" 2>/dev/null)"
    [[ -z "$stat" ]]
}

retire_redundant_pr() {
    local pr="$1" branch="$2"
    local gap
    gap="$(gap_id_from_branch "$branch")"

    if (( DRY_RUN )); then
        echo "[pr-resolve-or-retire] DRY-RUN would retire #$pr (branch=$branch, redundant vs main)"
        return
    fi

    echo "[pr-resolve-or-retire] RETIRE #$pr — diff vs main is empty (redundant)"
    if ! gh pr close "$pr" --delete-branch \
        --comment "Retired by pr-resolve-or-retire.sh (INFRA-3614): this branch's diff against main is empty — the work is already merged. Closing + deleting the branch rather than leaving it CONFLICTING indefinitely." \
        2>&1 | tail -3; then
        echo "[pr-resolve-or-retire] FAIL #$pr — gh pr close failed"
        emit pr_resolve_or_retire_skip "$pr" "\"reason\":\"close_failed\",\"branch\":\"$branch\""
        return
    fi

    # Best-effort: if the branch name resolves to a real open/in_progress
    # gap, stamp closed_pr so the registry doesn't show it stranded.
    # Never fatal — retiring the PR is the load-bearing action here.
    if [[ -n "$gap" ]] && command -v chump >/dev/null 2>&1; then
        if chump gap show "$gap" >/dev/null 2>&1; then
            chump gap set "$gap" --closed-pr "$pr" >/dev/null 2>&1 || true
        fi
    fi

    emit pr_retired_redundant "$pr" "\"branch\":\"$branch\",\"gap\":\"${gap:-unknown}\""
}

attempt_content_rebase() {
    local pr="$1" branch="$2"
    local wt
    wt="$(mktemp -d -t chump-resolve-retire-XXXXXX)"

    git -C "$REPO_ROOT" fetch origin "$branch" --quiet 2>/dev/null || true
    git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true

    if ! git -C "$REPO_ROOT" worktree add "$wt" "origin/$branch" >/dev/null 2>&1; then
        echo "[pr-resolve-or-retire] FAIL #$pr — could not create worktree"
        rm -rf "$wt" 2>/dev/null || true
        return 1
    fi

    local ok=1
    if timeout 120s bash -c "cd '$wt' && git rebase origin/main" >/dev/null 2>&1; then
        if (( DRY_RUN )); then
            echo "[pr-resolve-or-retire] DRY-RUN would push content-rebase for #$pr"
            ok=0
        elif (cd "$wt" && git push origin "HEAD:$branch" --force-with-lease >/dev/null 2>&1); then
            echo "[pr-resolve-or-retire] OK #$pr — content-rebase resolved true conflict, pushed"
            emit pr_content_rebased "$pr" "\"branch\":\"$branch\""
            ok=0
        else
            echo "[pr-resolve-or-retire] FAIL #$pr — content-rebase OK but push failed"
        fi
    else
        (cd "$wt" && git rebase --abort >/dev/null 2>&1) || true
    fi

    git -C "$REPO_ROOT" worktree remove "$wt" --force >/dev/null 2>&1 || true
    rm -rf "$wt" 2>/dev/null || true
    return $ok
}

report_unresolvable() {
    local pr="$1" branch="$2"
    local conflict_files
    conflict_files="$(git -C "$REPO_ROOT" diff --name-only --diff-filter=U 2>/dev/null | \
        jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')"
    echo "[pr-resolve-or-retire] UNRESOLVABLE #$pr — true conflict, diff is non-empty (real, non-redundant work)"
    emit pr_conflict_unresolvable "$pr" "\"branch\":\"$branch\",\"conflict_files\":$conflict_files"
}

PRS_JSON="$(gh pr list --state open --limit 60 --json number,headRefName,mergeStateStatus 2>/dev/null || echo '[]')"
if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    echo "[pr-resolve-or-retire] no open PRs (or gh unavailable)"
    exit 0
fi

TARGETS="$(printf '%s' "$PRS_JSON" | jq -r '
    .[]
    | select(.mergeStateStatus == "DIRTY" or .mergeStateStatus == "CONFLICTING")
    | "\(.number)\t\(.headRefName)"
')"

if [[ -z "$TARGETS" ]]; then
    echo "[pr-resolve-or-retire] no DIRTY/CONFLICTING PRs"
    exit 0
fi

git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true

RETIRED=0
REBASED=0
UNRESOLVED=0
while IFS=$'\t' read -r PR BRANCH; do
    [[ -z "$PR" || -z "$BRANCH" ]] && continue

    if branch_diff_is_empty "$BRANCH"; then
        retire_redundant_pr "$PR" "$BRANCH"
        RETIRED=$((RETIRED+1))
        continue
    fi

    if attempt_content_rebase "$PR" "$BRANCH"; then
        REBASED=$((REBASED+1))
    else
        report_unresolvable "$PR" "$BRANCH"
        UNRESOLVED=$((UNRESOLVED+1))
    fi
done <<< "$TARGETS"

echo "[pr-resolve-or-retire] done — retired=$RETIRED content-rebased=$REBASED unresolvable=$UNRESOLVED"
exit 0
