#!/usr/bin/env bash
# scripts/coord/pr-auto-rebase.sh — INFRA-1777
#
# Auto-rebase any open PR whose ONLY blocker is "behind on main" and which
# already has auto-merge armed. Eliminates the manual `gh pr update-branch`
# step after every keystone-fix lands.
#
# Tonight's reproducer (2026-05-23 ~05:18Z):
#   PR #2381 + #2382 landed at 05:17/05:18Z. PRs #2377 + #2373 were DIRTY,
#   armed for auto-merge, and waiting on EXACTLY those allowlist additions.
#   The keystone-cascade detector (INFRA-1420) didn't fire because the
#   batch-fix commits had no `unblocks-cluster:` trailer. Operator ran
#   `gh pr update-branch 2377 2373` manually. That's the friction this
#   script eliminates.
#
# Usage:
#   bash scripts/coord/pr-auto-rebase.sh [--dry-run] [--max-per-hour N]
#
# Run periodically (every 3-5 min). Install via launchd plist:
#   scripts/setup/install-pr-auto-rebase-launchd.sh (follow-up gap)
#
# Telemetry:
#   kind=pr_auto_rebased         — successful rebase + push (via gh API)
#   kind=pr_auto_rebase_skipped  — cooldown / not-armed / not-behind
#   kind=pr_auto_rebase_failed   — BOTH gh API and local rebase failed (true conflict)
#   kind=pr_auto_rebase_fallback — gh API false-positive, local rebase succeeded (INFRA-1958)
#
# INFRA-1958 (2026-05-24): `gh pr update-branch` returns non-zero with false-positive
# "conflict" reports for PRs that local `git rebase origin/main` resolves cleanly with
# zero conflicts. On 2026-05-24, 8 PRs (#2514-#2543) wedged for hours on this bug while
# fleet throughput collapsed to ~0 merges/hour. Fix: when gh API reports conflict, try
# local rebase in /tmp worktree; if it succeeds, push --force-with-lease and continue.
# Only escalate to pr_auto_rebase_failed if local rebase ALSO fails.
#
# Bypass: CHUMP_PR_AUTO_REBASE_NO_FALLBACK=1 disables local-rebase fallback (trust gh API).

set -uo pipefail

DRY_RUN=0
MAX_PER_HOUR=4
for a in "$@"; do
    case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --max-per-hour) shift; MAX_PER_HOUR="$1" ;;
    --max-per-hour=*) MAX_PER_HOUR="${a#*=}" ;;
    esac
done

# Locate repo + ambient log.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
COOLDOWN_FILE="$REPO_ROOT/.chump-locks/pr-auto-rebase-cooldown.jsonl"
mkdir -p "$(dirname "$COOLDOWN_FILE")"
touch "$COOLDOWN_FILE"

emit() {
    # $1=kind  $2=pr  $3=extra-fields (json fragment, optional)
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

# How many times in the last hour have we rebased this PR? Caps runaway loops.
cooldown_count() {
    local pr="$1"
    local cutoff
    # macOS date doesn't have --date easily; use perl one-liner for portability.
    cutoff="$(perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-3600))')"
    awk -v pr="$pr" -v cutoff="$cutoff" -F '"' '
        $0 ~ ("\"pr\":" pr "[,}]") {
            # Extract ts (second quoted field)
            if ($4 >= cutoff) c++
        }
        END { print (c ? c : 0) }
    ' "$COOLDOWN_FILE"
}

# Find DIRTY-or-BEHIND PRs with auto-merge armed.
PRS_JSON="$(gh pr list \
    --state open \
    --limit 60 \
    --json number,mergeStateStatus,autoMergeRequest 2>/dev/null || echo '[]')"

if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    echo "[pr-auto-rebase] no open PRs (or gh unavailable)"
    exit 0
fi

# Targets: armed + (DIRTY|BEHIND|BLOCKED).
# INFRA-1838: BLOCKED added to handle the case where CI ran against an older
# main and is now stale (today's 2026-05-23 cascade: 13 PRs sat BLOCKED for
# hours because the old filter only caught DIRTY/BEHIND). Cooldown
# (MAX_PER_HOUR) prevents runaway nudging of PRs that are BLOCKED for genuine
# CI failure reasons.
#
# Bypass: CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED=1 reverts to pre-INFRA-1838
#         filter (DIRTY|BEHIND only) — for forensic debugging.
STATE_FILTER='.mergeStateStatus == "DIRTY" or .mergeStateStatus == "BEHIND" or .mergeStateStatus == "BLOCKED"'
if [[ "${CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED:-0}" == "1" ]]; then
    STATE_FILTER='.mergeStateStatus == "DIRTY" or .mergeStateStatus == "BEHIND"'
fi
TARGETS="$(printf '%s' "$PRS_JSON" | jq -r '
    .[]
    | select(.autoMergeRequest != null)
    | select('"$STATE_FILTER"')
    | "\(.number)\t\(.mergeStateStatus)"
')"

if [[ -z "$TARGETS" ]]; then
    echo "[pr-auto-rebase] no armed PRs needing rebase (DIRTY/BEHIND/BLOCKED)"
    exit 0
fi

REBASED=0
SKIPPED=0
FAILED=0
DEFERRED=0
while IFS=$'\t' read -r PR STATE; do
    [[ -z "$PR" ]] && continue
    count="$(cooldown_count "$PR")"
    if (( count >= MAX_PER_HOUR )); then
        echo "[pr-auto-rebase] SKIP #$PR — cooldown ($count rebases in last hour, max=$MAX_PER_HOUR)"
        emit pr_auto_rebase_skipped "$PR" "\"reason\":\"cooldown\",\"count_last_hour\":$count"
        SKIPPED=$((SKIPPED+1))
        continue
    fi
    if (( DRY_RUN )); then
        echo "[pr-auto-rebase] DRY-RUN would rebase #$PR (state=$STATE, prior rebases this hour=$count)"
        continue
    fi

    # INFRA-1974 (H5 critique fix): per-branch advisory lock. Prevents this
    # daemon from racing an operator-initiated `git rebase origin/main` on
    # the same branch — observed live on 2026-05-25 04:51:46Z (PR #2566) and
    # again at 16:31:07Z (PR #2574) where the daemon's parallel rebase
    # produced a duplicate CI run that doubled the queue cost. Operator
    # rebases should take `flock -n .chump-locks/rebase-<branch>.lock`
    # before touching the branch; that's a follow-up gap. For now the
    # daemon side defers cleanly when the lock can't be acquired.
    #
    # Bypass: CHUMP_PR_AUTO_REBASE_NO_LOCK=1 reverts to pre-1974 behavior
    # (always rebase regardless of operator activity).
    BRANCH="$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null)"
    if [[ -z "$BRANCH" ]]; then
        echo "[pr-auto-rebase] WARN #$PR — could not resolve branch name; skipping"
        emit pr_auto_rebase_skipped "$PR" "\"reason\":\"branch_resolve_failed\""
        SKIPPED=$((SKIPPED+1))
        continue
    fi
    # Sanitize branch name for use in filename (e.g. chump/foo-bar → chump_foo-bar)
    BRANCH_SAFE="${BRANCH//\//_}"
    LOCKFILE="$REPO_ROOT/.chump-locks/rebase-${BRANCH_SAFE}.lock"
    if [[ "${CHUMP_PR_AUTO_REBASE_NO_LOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
        # Acquire lock in subshell so it auto-releases at scope exit. If we
        # can't get it in 1s, defer this PR — operator is rebasing.
        REBASE_OUTPUT_FILE="$(mktemp)"
        REBASE_EXIT=0
        (
            exec 9>"$LOCKFILE"
            if ! flock -n -w 1 9; then
                echo "[pr-auto-rebase] DEFER #$PR — branch $BRANCH lock held (operator rebasing?)"
                emit pr_auto_rebase_deferred_for_operator "$PR" "\"reason\":\"lock_held\",\"branch\":\"$BRANCH\""
                exit 2  # signal deferred to outer
            fi
            # Lock held — do the rebase. Re-source the logic by exporting and
            # re-running the core action; simpler to just inline a redirect.
            true
        )
        if [[ $? -eq 2 ]]; then
            DEFERRED=$((DEFERRED+1))
            rm -f "$REBASE_OUTPUT_FILE"
            continue
        fi
        rm -f "$REBASE_OUTPUT_FILE"
        # Re-acquire the lock for the actual rebase action below. Subshell
        # above proved the lock is available; this scope holds it through
        # the gh API + local-rebase fallback.
        exec 9>"$LOCKFILE"
        flock -n 9 || {
            echo "[pr-auto-rebase] DEFER #$PR — lock taken between probe and acquire (rare race)"
            emit pr_auto_rebase_deferred_for_operator "$PR" "\"reason\":\"lock_race\",\"branch\":\"$BRANCH\""
            DEFERRED=$((DEFERRED+1))
            exec 9>&-
            continue
        }
    fi

    echo "[pr-auto-rebase] rebasing #$PR (state=$STATE)..."
    if gh pr update-branch "$PR" 2>&1 | tail -3; then
        echo "[pr-auto-rebase] OK #$PR"
        emit pr_auto_rebased "$PR" "\"prior_state\":\"$STATE\",\"trigger\":\"chump-pr-auto-rebase\""
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","pr":%s,"state":"%s"}\n' "$ts" "$PR" "$STATE" >> "$COOLDOWN_FILE"
        REBASED=$((REBASED+1))
    else
        # INFRA-1958: gh pr update-branch returns false-positive conflicts.
        # Try local rebase fallback before escalating to pr_auto_rebase_failed.
        if [[ "${CHUMP_PR_AUTO_REBASE_NO_FALLBACK:-0}" == "1" ]]; then
            echo "[pr-auto-rebase] FAIL #$PR — gh pr update-branch returned non-zero (fallback disabled by env)"
            emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"disabled\""
            FAILED=$((FAILED+1))
            continue
        fi
        echo "[pr-auto-rebase] gh API reports conflict — trying local rebase fallback (INFRA-1958)..."
        BRANCH="$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null)"
        if [[ -z "$BRANCH" ]]; then
            echo "[pr-auto-rebase] FAIL #$PR — could not resolve branch name"
            emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"branch_resolve_failed\""
            FAILED=$((FAILED+1))
            continue
        fi
        WT="$(mktemp -d -t chump-rebase-fb-XXXXXX)"
        # Fetch the branch fresh; ignore failures (older git may not support --quiet).
        git -C "$REPO_ROOT" fetch origin "$BRANCH" --quiet 2>/dev/null || true
        git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true
        if git -C "$REPO_ROOT" worktree add "$WT" "origin/$BRANCH" >/dev/null 2>&1; then
            if (cd "$WT" && git rebase origin/main >/dev/null 2>&1); then
                # INFRA-1526: verify no hunks silently dropped before pushing.
                _prv_script="$REPO_ROOT/scripts/coord/post-rebase-verify.sh"
                _prv_failed=0
                if [[ -x "$_prv_script" ]] && [[ "${CHUMP_SKIP_POST_REBASE_VERIFY:-0}" != "1" ]]; then
                    CHUMP_REPO_ROOT="$WT" CHUMP_AMBIENT_LOG="$AMBIENT" \
                        bash "$_prv_script" --base origin/main || _prv_failed=1
                fi
                if [[ "$_prv_failed" -eq 1 ]]; then
                    echo "[pr-auto-rebase] FAIL #$PR — post-rebase verify caught hunk drop (kind=rebase_hunk_dropped emitted)"
                    emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"hunk_drop_detected\""
                    FAILED=$((FAILED+1))
                    git -C "$REPO_ROOT" worktree remove "$WT" --force >/dev/null 2>&1 || true
                    rm -rf "$WT" 2>/dev/null || true
                    continue
                fi
                if (cd "$WT" && git push origin "HEAD:$BRANCH" --force-with-lease >/dev/null 2>&1); then
                    echo "[pr-auto-rebase] OK #$PR — local-rebase fallback succeeded (gh API was false-positive)"
                    emit pr_auto_rebase_fallback "$PR" "\"prior_state\":\"$STATE\",\"trigger\":\"chump-pr-auto-rebase\",\"reason\":\"gh_api_false_positive\""
                    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    printf '{"ts":"%s","pr":%s,"state":"%s"}\n' "$ts" "$PR" "$STATE" >> "$COOLDOWN_FILE"
                    REBASED=$((REBASED+1))
                else
                    echo "[pr-auto-rebase] FAIL #$PR — local rebase OK but push failed (lock contention?)"
                    emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"push_failed\""
                    FAILED=$((FAILED+1))
                fi
            else
                # Abort any in-progress rebase before removing worktree
                (cd "$WT" && git rebase --abort >/dev/null 2>&1) || true
                echo "[pr-auto-rebase] FAIL #$PR — true conflict confirmed by local rebase (sibling rescue needed)"
                emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"local_rebase_also_failed\""
                FAILED=$((FAILED+1))
            fi
            git -C "$REPO_ROOT" worktree remove "$WT" --force >/dev/null 2>&1 || true
        else
            echo "[pr-auto-rebase] FAIL #$PR — could not create worktree for fallback"
            emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\",\"fallback\":\"worktree_failed\""
            FAILED=$((FAILED+1))
        fi
        rm -rf "$WT" 2>/dev/null || true
    fi

    # INFRA-1974: release per-branch lock at end of iteration so the next
    # PR's iteration starts clean. The fd 9 was opened above with `exec`
    # which has loop-scope; close explicitly to release flock.
    if [[ "${CHUMP_PR_AUTO_REBASE_NO_LOCK:-0}" != "1" ]] && command -v flock >/dev/null 2>&1; then
        exec 9>&- 2>/dev/null || true
    fi
done <<< "$TARGETS"

echo "[pr-auto-rebase] done — rebased=$REBASED skipped=$SKIPPED failed=$FAILED deferred=$DEFERRED"
exit 0
