#!/usr/bin/env bash
# poll-cross-workflow-checks.sh — CREDIBLE-269 (SHIP-INFRA 1/7)
#
# audit.yml and integrations.yml (ACP protocol smoke test) are separate
# GitHub Actions workflows from ci.yml, so the `verified` aggregator job
# cannot pull their results via same-workflow `needs:`. This script polls
# the Checks API for a given commit SHA until every named check reaches a
# terminal state (or a timeout is hit), then prints one `name=result` line
# per check in the exact vocabulary scripts/ci/aggregator-verified.sh already
# understands (success | failure | cancelled | skipped).
#
# A check that never resolves before --timeout-s is reported as `failure`
# (fail-closed) rather than left dangling — a GitHub Actions job step can
# only be success/failure on exit, so there is no real "pending" outcome to
# hand back to the caller; timing out MUST block the merge, not leave it
# ambiguous (the exact "wedge waiting on a context that'll never post"
# failure mode this aggregator replaces).
#
# Usage:
#   poll-cross-workflow-checks.sh --sha SHA --check "name" [--check "name" ...] \
#       [--repo owner/repo] [--timeout-s N] [--interval-s N]
#
# Requires: gh CLI (authenticated via GH_TOKEN/GITHUB_TOKEN), jq.

set -euo pipefail

REPO="${GH_REPO:-repairman29/chump}"
SHA=""
CHECKS=()
TIMEOUT_S=600
INTERVAL_S=15

usage() {
    grep '^#' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sha)         SHA="$2"; shift 2 ;;
        --check)       CHECKS+=("$2"); shift 2 ;;
        --repo)        REPO="$2"; shift 2 ;;
        --timeout-s)   TIMEOUT_S="$2"; shift 2 ;;
        --interval-s)  INTERVAL_S="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "[poll-cross-workflow-checks] unknown arg: $1" >&2; exit 3 ;;
    esac
done

if [[ -z "$SHA" || ${#CHECKS[@]} -eq 0 ]]; then
    echo "[poll-cross-workflow-checks] ERROR: --sha and at least one --check are required" >&2
    exit 3
fi

deadline=$(( $(date +%s) + TIMEOUT_S ))
declare -A RESULT
for c in "${CHECKS[@]}"; do RESULT["$c"]="in_progress"; done

fetch_check_runs() {
    gh api "repos/${REPO}/commits/${SHA}/check-runs" --paginate -q '.check_runs' 2>/dev/null || echo '[]'
}

while true; do
    runs_json="$(fetch_check_runs)"
    all_terminal=1
    for c in "${CHECKS[@]}"; do
        entry="$(echo "$runs_json" | jq -c --arg n "$c" '[.[] | select(.name == $n)] | sort_by(.started_at) | last // empty')"
        if [[ -z "$entry" ]]; then
            all_terminal=0
            continue
        fi
        status="$(echo "$entry" | jq -r '.status')"
        if [[ "$status" != "completed" ]]; then
            all_terminal=0
            continue
        fi
        conclusion="$(echo "$entry" | jq -r '.conclusion // ""')"
        case "$conclusion" in
            success)                            RESULT["$c"]="success" ;;
            failure|timed_out|action_required|stale) RESULT["$c"]="failure" ;;
            cancelled)                           RESULT["$c"]="cancelled" ;;
            skipped|neutral)                     RESULT["$c"]="skipped" ;;
            *)                                   RESULT["$c"]="failure" ;;
        esac
    done

    if [[ "$all_terminal" -eq 1 ]]; then
        break
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
        echo "[poll-cross-workflow-checks] WARN: timed out after ${TIMEOUT_S}s waiting on: ${CHECKS[*]} (fail-closed)" >&2
        break
    fi
    sleep "$INTERVAL_S"
done

for c in "${CHECKS[@]}"; do
    # fail-closed: anything still in_progress at loop-exit (timeout) reports failure
    [[ "${RESULT[$c]}" == "in_progress" ]] && RESULT["$c"]="failure"
    printf '%s=%s\n' "$c" "${RESULT[$c]}"
done
