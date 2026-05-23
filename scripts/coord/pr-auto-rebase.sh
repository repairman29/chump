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
#   kind=pr_auto_rebased      — successful rebase + push
#   kind=pr_auto_rebase_skipped — cooldown / not-armed / not-behind
#   kind=pr_auto_rebase_failed  — gh pr update-branch returned non-zero

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
    echo "[pr-auto-rebase] rebasing #$PR (state=$STATE)..."
    if gh pr update-branch "$PR" 2>&1 | tail -3; then
        echo "[pr-auto-rebase] OK #$PR"
        emit pr_auto_rebased "$PR" "\"prior_state\":\"$STATE\",\"trigger\":\"chump-pr-auto-rebase\""
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","pr":%s,"state":"%s"}\n' "$ts" "$PR" "$STATE" >> "$COOLDOWN_FILE"
        REBASED=$((REBASED+1))
    else
        echo "[pr-auto-rebase] FAIL #$PR — gh pr update-branch returned non-zero (likely true conflict; sibling rescue or operator action needed)"
        emit pr_auto_rebase_failed "$PR" "\"prior_state\":\"$STATE\""
        FAILED=$((FAILED+1))
    fi
done <<< "$TARGETS"

echo "[pr-auto-rebase] done — rebased=$REBASED skipped=$SKIPPED failed=$FAILED"
exit 0
