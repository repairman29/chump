#!/usr/bin/env bash
# armed-pr-rebaser.sh — INFRA-3473. Fleet self-healing.
#
# The queue-driver rebases BEHIND PRs and conflict-resolver-agent.sh resolves
# conflicts — but only INSIDE a bot-merge run. Once a PR is armed and bot-merge
# exits, nothing re-runs rebase when main later advances, so armed PRs drift to
# CONFLICTING/DIRTY and sit until a human notices (found 2026-07-28: #3347/#3353/
# #3362 sat for hours; 2 of 3 only needed a plain rebase).
#
# This closes that gap: for each open ARMED PR whose mergeStateStatus is DIRTY or
# BEHIND, rebase its branch on origin/main in a throwaway worktree; if the rebase
# is CLEAN, push --force-with-lease (auto-merge then lands it); if there's a REAL
# conflict, abort and emit `armed_pr_needs_conflict_resolution` for a human /
# conflict-resolver — NEVER force-push a broken state.
set -uo pipefail

REPO="${CHUMP_PR_REPO:-repairman29/chump}"
ROOT="${CHUMP_REPO_ROOT:-$HOME/Projects/Chump}"
AMB="$ROOT/.chump-locks/ambient.jsonl"
cd "$ROOT" 2>/dev/null || exit 1
command -v gh >/dev/null 2>&1 || exit 0
git fetch origin main --quiet 2>/dev/null || true

prs="$(gh pr list --repo "$REPO" --state open \
        --json number,mergeStateStatus,autoMergeRequest,headRefName 2>/dev/null \
    | python3 -c "import sys,json
for p in json.load(sys.stdin):
    if p.get('autoMergeRequest') and p.get('mergeStateStatus') in ('DIRTY','BEHIND'):
        print(p['number'], p['headRefName'])" 2>/dev/null)"
[ -z "$prs" ] && exit 0

while read -r num br; do
    [ -z "$num" ] && continue
    git fetch origin "$br" --quiet 2>/dev/null || continue
    wt="/tmp/armed-rebaser-$num"
    git worktree remove "$wt" --force 2>/dev/null || true
    git worktree add "$wt" "$br" >/dev/null 2>&1 || continue
    (
        cd "$wt" || exit 0
        if git rebase origin/main >/dev/null 2>&1 \
           && [ -z "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
            if git push origin "$br" --force-with-lease >/dev/null 2>&1; then
                echo "[armed-pr-rebaser] #$num: rebased clean + pushed → mergeable"
            fi
        else
            git rebase --abort 2>/dev/null || true
            printf '{"ts":"%s","kind":"armed_pr_needs_conflict_resolution","pr":%s,"branch":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$num" "$br" >> "$AMB" 2>/dev/null || true
            echo "[armed-pr-rebaser] #$num: REAL conflict — flagged for resolution (not force-pushed)"
        fi
    )
    git worktree remove "$wt" --force 2>/dev/null || true
done <<< "$prs"
