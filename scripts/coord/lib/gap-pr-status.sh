#!/usr/bin/env bash
# scripts/coord/lib/gap-pr-status.sh — INFRA-1221
#
# Helper: does the gap have an active open PR? Used to protect a claim
# from being reaped while the PR is in flight.
#
# Today's pattern (audit 2026-05-14): claim and PR-open are independent
# states. A worker claims a gap, makes 10 commits, pushes, opens PR,
# then the lease TTLs while CI runs. The stale-gap-lock-reaper demotes
# the claim → another worker picks up → duplicates the work. With this
# helper, the reaper can recognize "PR is in flight, leave the claim
# alone."
#
# This is the lightweight implementation of INFRA-1221's gap state
# extension. The PR itself is the durable signal — no schema change
# required. Full state-machine version with explicit pr_opened column
# in state.db is deferred (filed as follow-up).
#
# Public API:
#   gap_has_open_pr <GAP-ID>     → exits 0 if open PR exists, 1 otherwise
#   gap_open_pr_number <GAP-ID>  → prints PR number(s), one per line

[[ -n "${_CHUMP_GAP_PR_STATUS_LOADED:-}" ]] && return 0
_CHUMP_GAP_PR_STATUS_LOADED=1

_gap_pr_status_check() {
    local gap_id="${1:-}"
    [[ -z "$gap_id" ]] && return 1
    command -v gh >/dev/null 2>&1 || return 1
    local repo
    repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || return 1
    [[ -z "$repo" ]] && return 1
    # Use the same word-boundary regex as pr-dedup.sh so the two stay aligned.
    local list
    list="$(gh api "repos/$repo/pulls?state=open&per_page=100" \
        --jq '.[] | "\(.number) \(.title)"' 2>/dev/null)" || return 1
    [[ -z "$list" ]] && return 1
    local pattern="(^|[^A-Za-z0-9-])${gap_id}([^0-9]|\$)"
    echo "$list" | awk -v p="$pattern" '$0 ~ p {print $1}'
}

# Exit 0 if any open PR cites the gap-ID; exit 1 otherwise.
gap_has_open_pr() {
    local out
    out="$(_gap_pr_status_check "$1")" || return 1
    [[ -n "$out" ]]
}

# Print all PR numbers (one per line) for open PRs citing this gap-ID.
gap_open_pr_number() {
    _gap_pr_status_check "$1"
}
