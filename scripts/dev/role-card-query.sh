#!/usr/bin/env bash
# scripts/dev/role-card-query.sh — INFRA-2017 (RCA Change 2 follow-up)
#
# Reads the ambient.jsonl tail for kind=role_card events and returns the
# latest role-card PER PHYSICAL SESSION — deduped by session_id, NOT by
# alias. A single physical session may emit multiple role_card events
# under different aliases over its lifetime (role-switch within a
# shell); this query collapses those into one entry per session_id with
# the union of aliases seen, so peers doing dispatch dedup see "one
# agent, N hats" instead of N phantom agents.
#
# Usage:
#   scripts/dev/role-card-query.sh [--since Nh] [--session-id <id>] [--tail N]
#
# Output: JSON array, one object per distinct session_id:
#   {session_id, aliases: [...], primary_lane, active_claim, wake_mode, ts}
#   (primary_lane/active_claim/wake_mode/ts come from that session's most
#   recent role_card event; aliases is the union across all its events.)
#
# Environment:
#   CHUMP_AMBIENT_LOG   override the log path (default: <repo>/.chump-locks/ambient.jsonl)

set -euo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

SINCE_HOURS=""
SESSION_FILTER=""
TAIL_N="5000"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since)
            SINCE_HOURS="${2%h}"; shift 2
            if ! [[ "$SINCE_HOURS" =~ ^[0-9]+$ ]]; then
                echo "role-card-query: --since requires an integer hours value (e.g. '1h')" >&2
                exit 2
            fi
            ;;
        --session-id) SESSION_FILTER="${2:-}"; shift 2 ;;
        --tail) TAIL_N="${2:-}"; shift 2 ;;
        --help|-h)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) shift ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    echo "role-card-query: jq is required" >&2
    exit 1
fi

if [[ ! -f "$AMBIENT" ]]; then
    echo "[]"
    exit 0
fi

CUTOFF_ARG="null"
if [[ -n "$SINCE_HOURS" ]]; then
    CUTOFF_ARG="$(date -u -d "-${SINCE_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v-"${SINCE_HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "")"
    [[ -z "$CUTOFF_ARG" ]] && CUTOFF_ARG="null" || CUTOFF_ARG="\"$CUTOFF_ARG\""
fi

tail -n "$TAIL_N" "$AMBIENT" 2>/dev/null \
    | jq -c 'select(.kind? == "role_card")' 2>/dev/null \
    | jq -s \
        --arg session_filter "$SESSION_FILTER" \
        --argjson cutoff "$CUTOFF_ARG" '
    map(select($session_filter == "" or .session_id == $session_filter))
  | map(select($cutoff == null or .ts >= $cutoff))
  | group_by(.session_id)
  | map(
      (sort_by(.ts)) as $events
      | {
          session_id: .[0].session_id,
          aliases: ([$events[].aliases[]?] | unique),
          primary_lane: ($events | last).primary_lane,
          active_claim: ($events | last).active_claim,
          wake_mode: ($events | last).wake_mode,
          ts: ($events | last).ts
        }
    )
'
