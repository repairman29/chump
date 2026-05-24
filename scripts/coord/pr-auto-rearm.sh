#!/usr/bin/env bash
# scripts/coord/pr-auto-rearm.sh — INFRA-1907
#
# Safety-net daemon: sweep open PRs every 5 min; for any in BLOCKED state
# with auto-merge disarmed (autoMergeRequest == null), re-arm via
# `gh pr merge $pr --auto --squash`.
#
# Why: GitHub's auto-merge contract is per-tree. Force-push, update-branch,
# close+reopen, and branch-protection changes ALL silently disarm. Without
# a sweeper, PRs sit BLOCKED+OFF forever waiting for an operator to notice.
# Today's session lost 7 PRs to this exact pattern.
#
# Complements INFRA-1906 (pr-auto-rebase re-arms inline after its own
# update-branch). This daemon catches the OTHER disarm causes too.
#
# Throttle: same PR won't re-arm within 30 min (.chump-locks/pr-auto-rearm-state.jsonl)
# to avoid loops on a PR that's genuinely supposed to stay disarmed.
#
# Bypass: CHUMP_PR_AUTO_REARM_DISABLED=1.

set -uo pipefail

# Quick bypass
[[ "${CHUMP_PR_AUTO_REARM_DISABLED:-0}" == "1" ]] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE="$REPO_ROOT/.chump-locks/pr-auto-rearm-state.jsonl"
THROTTLE_MIN="${CHUMP_PR_AUTO_REARM_THROTTLE_MIN:-30}"
mkdir -p "$(dirname "$STATE")"
touch "$STATE"

# Compute cutoff: now - THROTTLE_MIN minutes (ISO-8601 UTC for string compare)
cutoff="$(perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - '"$THROTTLE_MIN"' * 60))' 2>/dev/null)"

# Last re-arm timestamp for this PR (within throttle window). Empty if none.
recent_rearm() {
    local pr="$1"
    awk -v pr="$pr" -v cutoff="$cutoff" -F'"' '
        $0 ~ ("\"pr\":" pr "[,}]") {
            # Extract ts (the second quoted string in the JSON line)
            if ($4 >= cutoff) { print $4; exit }
        }
    ' "$STATE"
}

emit() {
    local pr="$1" reason="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"pr_auto_rearmed","pr":%s,"prior_disarm_reason":"%s"}\n' \
        "$ts" "$pr" "$reason" >> "$AMBIENT"
}

record() {
    local pr="$1"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","pr":%s}\n' "$ts" "$pr" >> "$STATE"
}

# Query open PRs that are BLOCKED with auto-merge disarmed
PRS_JSON="$(gh pr list --state open --limit 60 \
    --json number,mergeStateStatus,autoMergeRequest 2>/dev/null || echo '[]')"

if [[ -z "$PRS_JSON" || "$PRS_JSON" == "[]" ]]; then
    echo "[pr-auto-rearm] no open PRs (or gh unavailable)"
    exit 0
fi

# Targets: state BLOCKED, autoMergeRequest is null (disarmed)
TARGETS="$(printf '%s' "$PRS_JSON" | jq -r '
    .[]
    | select(.mergeStateStatus == "BLOCKED")
    | select(.autoMergeRequest == null)
    | .number
')"

if [[ -z "$TARGETS" ]]; then
    echo "[pr-auto-rearm] no disarmed BLOCKED PRs (queue healthy)"
    exit 0
fi

REARMED=0
THROTTLED=0
FAILED=0
while IFS= read -r PR; do
    [[ -z "$PR" ]] && continue
    last="$(recent_rearm "$PR")"
    if [[ -n "$last" ]]; then
        echo "[pr-auto-rearm] SKIP #$PR — re-armed at $last (within ${THROTTLE_MIN}min throttle)"
        THROTTLED=$((THROTTLED + 1))
        continue
    fi
    echo "[pr-auto-rearm] re-arming #$PR..."
    if gh pr merge "$PR" --auto --squash >/dev/null 2>&1; then
        echo "[pr-auto-rearm] OK #$PR"
        emit "$PR" "blocked_disarmed_safety_sweep"
        record "$PR"
        REARMED=$((REARMED + 1))
    else
        echo "[pr-auto-rearm] FAIL #$PR — gh pr merge --auto returned non-zero"
        FAILED=$((FAILED + 1))
    fi
done <<< "$TARGETS"

echo "[pr-auto-rearm] done — rearmed=$REARMED throttled=$THROTTLED failed=$FAILED"
exit 0
