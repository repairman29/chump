#!/usr/bin/env bash
# scripts/coord/lib/pr-dedup.sh — INFRA-1219
#
# Pre-pr-create dedup gate. Catches the 80% case of parallel-work waste:
# two agents claim a gap (or one's claim TTLs while another picks up), both
# implement, both push, both `gh pr create` — second PR ships nothing because
# the first wins the merge. The losing PR's CI compute, reviewer attention,
# and tokens are wasted.
#
# Today's audit (2026-05-14): 57 of 79 closed-not-merged PRs in the last 14
# days were exactly this pattern.
#
# Usage:
#   source scripts/coord/lib/pr-dedup.sh
#   check_pr_dedup <current-branch> <gap-id> [<gap-id>...]
#
# Returns 0 if no open PR exists for any of the supplied gap IDs (other
# than current-branch, which may already have a PR from a re-push).
# Returns 1 with details on stderr if a duplicate is found.
#
# Per-PR opt-out: CHUMP_PR_DEDUP_BYPASS=1 (caller must include a
# `Dedup-Bypass-Reason: <one-liner>` trailer in the commit body for audit).
#
# Cost: one `gh api .../pulls` REST call. Hits the core bucket, not
# GraphQL — so the dedup check itself doesn't compete with merge
# arming for the GraphQL quota.

[[ -n "${_CHUMP_PR_DEDUP_LOADED:-}" ]] && return 0
_CHUMP_PR_DEDUP_LOADED=1

check_pr_dedup() {
    local current_branch="${1:-}"
    shift || true
    local gap_ids=("$@")
    [[ ${#gap_ids[@]} -eq 0 ]] && return 0
    [[ "${CHUMP_PR_DEDUP_BYPASS:-0}" == "1" ]] && return 0

    local repo
    repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || return 0
    [[ -z "$repo" ]] && return 0

    # One REST call gets us every open PR. Format: "<number> <branch> <title>"
    local all_open
    all_open="$(gh api "repos/$repo/pulls?state=open&per_page=100" \
        --jq '.[] | "\(.number) \(.head.ref) \(.title)"' 2>/dev/null)" || return 0
    [[ -z "$all_open" ]] && return 0

    local violation=0
    local violation_msg=""
    local gap_id
    for gap_id in "${gap_ids[@]}"; do
        [[ -z "$gap_id" ]] && continue
        # Match the gap ID as a word boundary in the title (avoid false-positive
        # matches like INFRA-12 hitting INFRA-123). Require a non-alphanumeric
        # non-hyphen char (or line start) BEFORE the id, and not-a-digit (or
        # line end) AFTER. Handles `fix(INFRA-100):`, `feat: INFRA-100 — …`,
        # and bare `INFRA-100` alike.
        local pattern="(^|[^A-Za-z0-9-])${gap_id}([^0-9]|\$)"
        local hits
        hits="$(echo "$all_open" | awk -v p="$pattern" '$0 ~ p {print}')" || true
        [[ -z "$hits" ]] && continue

        # Filter out PRs on the current branch — we may be re-pushing and the
        # existing PR is our own from a prior step.
        local foreign
        foreign="$(echo "$hits" | awk -v b="$current_branch" '$2 != b {print}')" || true
        [[ -z "$foreign" ]] && continue

        violation=1
        violation_msg+="  ${gap_id} already has open PR(s):"$'\n'
        violation_msg+="$(echo "$foreign" | sed 's|^|    |')"$'\n'
    done

    if [[ "$violation" -eq 1 ]]; then
        printf '[pr-dedup] INFRA-1219 — refusing to open PR (duplicate gap-ID in open queue):\n' >&2
        printf '%s' "$violation_msg" >&2
        printf '  Resolution options:\n' >&2
        printf '    1. Close one of the existing PRs (the older / staler one)\n' >&2
        printf '    2. Push your work onto the existing PR branch instead of opening a new PR\n' >&2
        printf '    3. Bypass with justification:\n' >&2
        printf '       CHUMP_PR_DEDUP_BYPASS=1  + add Dedup-Bypass-Reason: <why> trailer to commit body\n' >&2
        return 1
    fi

    return 0
}
