#!/usr/bin/env bash
# scripts/dispatch/lib/pr-terminal-state.sh — INFRA-1981 (M3 critique fix)
#
# Determine the TRUE terminal state of a GitHub PR, ignoring transient
# CLOSED flashes that occur during force-push reindex windows.
#
# The problem: `gh pr view --json state --jq .state` returns the value
# "CLOSED" for a brief window (~1-30s) after a force-push that triggers
# auto-rearm re-evaluation. The PR is NOT actually closed — `.mergedAt`
# is still being computed and the auto-merge resolution is in flight.
# Monitors that exit on state=="CLOSED" alone get fooled and miss the
# real terminal signal (MERGED).
#
# Observed 2x in 36h on PRs #2561 and #2566 (each ultimately MERGED).
#
# The fix: terminal-state is determined by `.mergedAt`, not `.state`.
# Caller asks for the terminal state; this helper:
#   1. queries the PR
#   2. if mergedAt != null -> MERGED (deterministic)
#   3. if state == OPEN -> OPEN
#   4. if state == CLOSED && mergedAt == null:
#        - re-query after 10s
#        - if STILL CLOSED && STILL null mergedAt -> GENUINELY_CLOSED
#        - if now has mergedAt -> MERGED
#        - if now OPEN (reopened) -> OPEN
#   5. unknown -> UNKNOWN
#
# Source it:
#   source "$(dirname "$0")/lib/pr-terminal-state.sh"
#
# API:
#   pr_terminal_state <pr-number> [--quick]
#     stdout: one of MERGED | GENUINELY_CLOSED | OPEN | UNKNOWN
#     rc=0 always (state is the output)
#     --quick: skip the 10s re-query (useful for unit tests; trades
#              false-CLOSED-tolerance for speed)
#
# Env:
#   CHUMP_PR_TERMINAL_REQUERY_DELAY_S — re-query delay (default 10).
#     Tune up for slower GitHub reindex; tune down for tests.

pr_terminal_state() {
    local pr="${1:?usage: pr_terminal_state <pr-number> [--quick]}"
    local quick=0
    if [ "${2:-}" = "--quick" ]; then
        quick=1
    fi
    local delay="${CHUMP_PR_TERMINAL_REQUERY_DELAY_S:-10}"

    local raw
    raw=$(gh pr view "$pr" --json state,mergedAt 2>/dev/null) || {
        echo "UNKNOWN"
        return 0
    }
    local state merged
    state=$(echo "$raw" | jq -r '.state // "UNKNOWN"')
    merged=$(echo "$raw" | jq -r '.mergedAt // "null"')

    # Rule 1: mergedAt != null → MERGED (deterministic; state value doesn't matter)
    if [ "$merged" != "null" ]; then
        echo "MERGED"
        return 0
    fi
    # Rule 2: still open → OPEN
    if [ "$state" = "OPEN" ]; then
        echo "OPEN"
        return 0
    fi
    # Rule 3: state == CLOSED && mergedAt == null → might be transient.
    if [ "$state" = "CLOSED" ]; then
        if [ "$quick" -eq 1 ]; then
            # Test mode: trust state immediately.
            echo "GENUINELY_CLOSED"
            return 0
        fi
        # Re-query after delay (lets GitHub finish reindex after force-push)
        sleep "$delay"
        raw=$(gh pr view "$pr" --json state,mergedAt 2>/dev/null) || {
            # Couldn't re-query — fall back to first answer.
            echo "GENUINELY_CLOSED"
            return 0
        }
        local state2 merged2
        state2=$(echo "$raw" | jq -r '.state // "UNKNOWN"')
        merged2=$(echo "$raw" | jq -r '.mergedAt // "null"')
        if [ "$merged2" != "null" ]; then
            # Was a transient CLOSED → actually MERGED.
            echo "MERGED"
            return 0
        fi
        if [ "$state2" = "OPEN" ]; then
            echo "OPEN"
            return 0
        fi
        # Still CLOSED, still null mergedAt → genuine close.
        echo "GENUINELY_CLOSED"
        return 0
    fi
    # Anything else (MERGED state without mergedAt — shouldn't happen — or unknown)
    echo "UNKNOWN"
    return 0
}

# Self-test when invoked directly: pr_terminal_state <pr>
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
    if [ -z "${1:-}" ]; then
        echo "usage: $0 <pr-number> [--quick]" >&2
        exit 1
    fi
    pr_terminal_state "$@"
fi
