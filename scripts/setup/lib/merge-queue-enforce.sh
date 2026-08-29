#!/usr/bin/env bash
# scripts/setup/lib/merge-queue-enforce.sh — INFRA-1518
#
# Merge Queue enforcement for `main`. Structural fix for INFRA-1377: Merge
# Queue on main was an operator-flip-the-switch step after every fleet up
# (the CONVOY-class failure diagnosed in that session). Sourced by
# chump-fleet-bootstrap.sh so every bootstrap run re-checks it and flips it
# back on if it was ever turned off.
#
# enforce_merge_queue <mode: check|install> <repo: owner/name>
#   prints one of: ok | enabled | missing | failed | skip-no-gh | skip-no-repo
#   exit 0 unless mode=check and the queue is disabled (then 1)

enforce_merge_queue() {
    local mode="$1" repo="$2"

    if ! command -v gh >/dev/null 2>&1; then
        echo "skip-no-gh"
        return 0
    fi
    if [[ -z "$repo" ]]; then
        echo "skip-no-repo"
        return 0
    fi

    local enabled
    enabled="$(gh api "repos/${repo}/branches/main/protection" \
        --jq '.required_pull_request_reviews.merge_queue.enabled // false' 2>/dev/null || echo false)"

    if [[ "$enabled" == "true" ]]; then
        echo "ok"
        return 0
    fi

    if [[ "$mode" == "check" ]]; then
        echo "missing"
        return 1
    fi

    if gh api --method PUT "repos/${repo}/branches/main/protection/required_pull_request_reviews" \
        -f 'merge_queue[grouping_strategy]=ALLGREEN' \
        -f 'merge_queue[merge_method]=SQUASH' \
        -F 'merge_queue[max_entries_to_build]=5' \
        -F 'merge_queue[max_entries_to_merge]=5' \
        -F 'merge_queue[min_entries_to_merge]=1' \
        -F 'merge_queue[min_entries_to_merge_wait_minutes]=1' \
        >/dev/null 2>&1; then
        echo "enabled"
        return 0
    fi

    echo "failed"
    return 1
}
