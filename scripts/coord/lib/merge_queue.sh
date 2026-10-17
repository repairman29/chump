#!/usr/bin/env bash
# scripts/coord/lib/merge_queue.sh — CREDIBLE-1510 (PHASE-R R3)
#
# Merge-queue awareness for every organ that rebases or force-pushes an open
# PR branch. Once main has a GitHub merge queue (a repository ruleset with a
# `merge_queue` rule, see docs/process/MERGE_QUEUE_FLIP.md), a PR that is
# already IN the queue must not be touched from outside: the queue builds its
# own merge_group commit on top of the latest main, and an external
# `gh pr update-branch` or `git push --force-with-lease` to the PR head
# EVICTS the entry (the batch is rebuilt and the PR goes to the back).
#
# gh pr list/view have no merge-queue JSON field (checked against gh 2.92:
# no isInMergeQueue / mergeQueueEntry in --json), so this asks GraphQL for
# the queue directly:
#   repository.mergeQueue(branch:) .entries.nodes[].pullRequest.number
# `mergeQueue` is null when no queue is configured for the branch, which
# prints nothing (no PR is queued), so this is safe to call before the flip.
#
# Usage (sourced):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/merge_queue.sh"
#   queued="$(merge_queue_numbers repairman29/chump main)" || <lookup failed>
#   merge_queue_contains "$queued" 1234 && echo "1234 is queued"
#
# Contract:
#   merge_queue_numbers <owner/repo> [branch=main] [gh-bin=gh]
#     stdout: one queued PR number per line (empty = nothing queued)
#     exit 0 = answer is known; exit 1 = the lookup itself failed (gh
#     non-zero). Callers treat exit 1 as "unknown" and FAIL CLOSED: skip the
#     mutation this cycle rather than risk evicting a queued entry. Output
#     that is not a bare integer is ignored, so a stub gh that prints `[]`
#     (the fleet's common test stub) reads as "nothing queued".
#   merge_queue_contains <newline-list> <pr-number>   exit 0 if listed

merge_queue_numbers() {
    local repo="${1:?merge_queue_numbers <owner/repo> [branch] [gh-bin]}"
    local branch="${2:-main}"
    local gh_bin="${3:-gh}"
    local owner="${repo%%/*}" name="${repo#*/}"
    local out
    # shellcheck disable=SC2016  # $owner/$name/$branch are GraphQL variables, not shell
    out="$(CHUMP_GH_CALL_CRITICALITY=background "$gh_bin" api graphql \
        -f query='query($owner:String!,$name:String!,$branch:String!){repository(owner:$owner,name:$name){mergeQueue(branch:$branch){entries(first:100){nodes{pullRequest{number}}}}}}' \
        -f owner="$owner" -f name="$name" -f branch="$branch" \
        --jq '.data.repository.mergeQueue.entries.nodes[]?.pullRequest.number' 2>/dev/null)" || return 1
    printf '%s\n' "$out" | grep -E '^[0-9]+$' || true
    return 0
}

merge_queue_contains() {
    local list="$1" pr="$2"
    [ -n "$list" ] && [ -n "$pr" ] || return 1
    grep -qx "$pr" <<< "$list"
}
