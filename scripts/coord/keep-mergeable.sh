#!/usr/bin/env bash
# scripts/coord/keep-mergeable.sh — RESILIENT-342
#
# "Keep-mergeable organ": continuously drive EVERY open fleet PR toward
# green-ready, not just armed (autoMergeRequest-set) ones.
#
# Evidence (2026-08-16): 6 open PRs, 3 DIRTY, 0 CLEAN. The existing
# rebaser (armed-pr-rebaser.sh, RESILIENT-289) only acts on PRs that
# already have auto-merge armed and is hardcoded to a Mac path — a PR
# that hasn't been armed yet (or was armed then un-armed by a failed
# check) rots into DIRTY/BEHIND with no organ driving it back to
# green-ready. This script closes that gap:
#
#   1. detect every open PR that is DIRTY/BEHIND (regardless of
#      autoMergeRequest), or CLEAN but with a required check that FAILED
#      against a stale (non-current) base commit
#   2. rebase DIRTY/BEHIND branches onto current green origin/main in a
#      throwaway worktree; push --force-with-lease on a clean rebase
#   3. rerun stale-failed required checks via `gh run rerun --failed`
#   4. escalate (ambient event + capped-frequency PR comment) any PR it
#      cannot auto-resolve (real conflict) instead of leaving it to rot
#
# Never force-pushes a broken/conflicted rebase. Portable repo root
# (unlike armed-pr-rebaser.sh's $HOME/Projects/Chump hardcode) — works
# from any worktree via `git rev-parse --show-toplevel`.
set -uo pipefail


# RESILIENT-342: route gh calls through throttled/cached wrapper (raw-gh lint INFRA-1274)
_KM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/github.sh
source "${_KM_DIR}/lib/github.sh"
REPO="${CHUMP_PR_REPO:-repairman29/chump}"
ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMB="$ROOT/.chump-locks/ambient.jsonl"
ESCALATE_BUDGET_DIR="${CHUMP_KEEP_MERGEABLE_BUDGET_DIR:-$ROOT/.chump-locks/keep-mergeable-budget}"
ESCALATE_COOLDOWN_S="${CHUMP_KEEP_MERGEABLE_ESCALATE_COOLDOWN_S:-21600}" # 6h
DRY_RUN="${CHUMP_KEEP_MERGEABLE_DRY_RUN:-0}"

mkdir -p "$ESCALATE_BUDGET_DIR" 2>/dev/null || true
cd "$ROOT" 2>/dev/null || exit 1
command -v gh >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
git fetch origin main --quiet 2>/dev/null || true

emit() {
    printf '%s\n' "$1" >> "$AMB" 2>/dev/null || true
}

now_s() { date -u +%s; }

# Emit an escalation at most once per ESCALATE_COOLDOWN_S per PR — avoids
# spamming ambient.jsonl / the PR thread every cycle for a PR a human
# hasn't gotten to yet.
escalate() {
    local num="$1" reason="$2"
    local marker="$ESCALATE_BUDGET_DIR/$num"
    local last=0
    [[ -f "$marker" ]] && last="$(cat "$marker" 2>/dev/null || echo 0)"
    local now; now="$(now_s)"
    if (( now - last < ESCALATE_COOLDOWN_S )); then
        return 0
    fi
    printf '%s' "$now" > "$marker" 2>/dev/null || true
    printf '{"ts":"%s","kind":"keep_mergeable_needs_escalation","pr":%s,"reason":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$num" "$reason" | tee -a "$AMB" >/dev/null 2>&1 || true
    if [[ "$DRY_RUN" != "1" ]]; then
        chump_gh pr comment "$num" --repo "$REPO" \
            --body "🔧 keep-mergeable organ: could not auto-resolve ($reason). Needs a human or conflict-resolver pass." \
            >/dev/null 2>&1 || true
    fi
}

# ── 1. Fetch every open PR's merge state + head sha ─────────────────────
prs_json="$(gh pr list --repo "$REPO" --state open \
    --json number,mergeStateStatus,headRefName,headRefOid 2>/dev/null)"
[[ -z "$prs_json" || "$prs_json" == "[]" ]] && exit 0

dirty_or_behind="$(printf '%s' "$prs_json" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    if p.get('mergeStateStatus') in ('DIRTY', 'BEHIND'):
        print(p['number'], p['headRefName'])
" 2>/dev/null)"

clean_prs="$(printf '%s' "$prs_json" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    if p.get('mergeStateStatus') == 'CLEAN':
        print(p['number'], p['headRefOid'])
" 2>/dev/null)"

rebased=0
escalated=0
rechecked=0

# ── 2. Rebase every DIRTY/BEHIND PR onto current green main ─────────────
if [[ -n "$dirty_or_behind" ]]; then
    while read -r num br; do
        [[ -z "$num" ]] && continue
        git fetch origin "$br" --quiet 2>/dev/null || { escalate "$num" "branch_fetch_failed"; continue; }
        wt="/tmp/keep-mergeable-$num"
        git worktree remove "$wt" --force 2>/dev/null || true
        if ! git worktree add "$wt" "$br" >/dev/null 2>&1; then
            escalate "$num" "worktree_add_failed"
            continue
        fi
        clean=0
        (
            cd "$wt" || exit 1
            if git rebase origin/main >/dev/null 2>&1 \
               && [[ -z "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]]; then
                exit 0
            else
                git rebase --abort 2>/dev/null || true
                exit 1
            fi
        )
        clean=$?
        if [[ "$clean" -eq 0 ]]; then
            if [[ "$DRY_RUN" == "1" ]]; then
                echo "[keep-mergeable] #$num: DRY_RUN, would push rebased $br"
            elif (cd "$wt" && git push origin "$br" --force-with-lease >/dev/null 2>&1); then
                emit "$(printf '{"ts":"%s","kind":"keep_mergeable_rebased","pr":%s,"branch":"%s"}' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$num" "$br")"
                echo "[keep-mergeable] #$num: rebased clean + pushed"
                rebased=$((rebased+1))
            else
                escalate "$num" "push_after_clean_rebase_failed"
            fi
        else
            escalate "$num" "real_conflict_on_rebase"
            escalated=$((escalated+1))
            echo "[keep-mergeable] #$num: REAL conflict — escalated, not force-pushed"
        fi
        git worktree remove "$wt" --force 2>/dev/null || true
    done <<< "$dirty_or_behind"
fi

# ── 3. Rerun stale-failed required checks on otherwise-CLEAN PRs ────────
# "Stale" here means: the failed check run's head sha still matches the
# PR's current head (so it's not simply outdated by a new push — that
# case is handled naturally by GitHub re-triggering checks) AND the
# failure happened before the PR's most recent rebase landed. We use a
# simpler, conservative proxy: any FAILED conclusion on the PR's current
# head sha is eligible for exactly one rerun per cooldown window, since a
# flake/stale-base failure and a genuine logic failure both start with
# one rerun attempt — a repeat failure after rerun is left for a human
# (ci-audit's lane), not looped on forever.
if [[ -n "$clean_prs" ]]; then
    while read -r num sha; do
        [[ -z "$num" ]] && continue
        failed_runs="$(gh api "repos/$REPO/commits/$sha/check-runs" --paginate \
            -q '.check_runs[] | select(.conclusion=="failure") | .check_suite.id' 2>/dev/null \
            | sort -u)"
        [[ -z "$failed_runs" ]] && continue
        marker="$ESCALATE_BUDGET_DIR/rerun-$num"
        last=0
        [[ -f "$marker" ]] && last="$(cat "$marker" 2>/dev/null || echo 0)"
        now="$(now_s)"
        if (( now - last < ESCALATE_COOLDOWN_S )); then
            continue
        fi
        printf '%s' "$now" > "$marker" 2>/dev/null || true
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[keep-mergeable] #$num: DRY_RUN, would rerun failed checks"
            continue
        fi
        did_rerun=0
        while read -r suite_id; do
            [[ -z "$suite_id" ]] && continue
            run_id="$(gh api "repos/$REPO/check-suites/$suite_id" -q '.id' 2>/dev/null)"
            [[ -z "$run_id" ]] && continue
            if gh run rerun "$run_id" --repo "$REPO" --failed >/dev/null 2>&1; then
                did_rerun=1
            fi
        done <<< "$failed_runs"
        if [[ "$did_rerun" -eq 1 ]]; then
            emit "$(printf '{"ts":"%s","kind":"keep_mergeable_checks_rerun","pr":%s,"sha":"%s"}' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$num" "$sha")"
            echo "[keep-mergeable] #$num: reran stale-failed checks"
            rechecked=$((rechecked+1))
        fi
    done <<< "$clean_prs"
fi

emit "$(printf '{"ts":"%s","kind":"keep_mergeable_tick","rebased":%s,"escalated":%s,"rechecked":%s}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rebased" "$escalated" "$rechecked")"
echo "[keep-mergeable] tick complete: rebased=$rebased escalated=$escalated rechecked=$rechecked"
