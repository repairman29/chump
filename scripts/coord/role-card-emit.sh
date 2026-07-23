#!/usr/bin/env bash
# scripts/coord/role-card-emit.sh — INFRA-2017 (RCA Change 2 follow-up)
#
# Emits kind=role_card to ambient.jsonl so peers can dedupe by physical
# session_id (the Claude Code session UUID) instead of guessing from
# alias/role-name, which the 2026-05-24 collision RCA (Change 2) flagged
# as a gap: a single physical session inhabiting multiple curator
# aliases over its lifetime (e.g. curator-opus-target then
# curator-opus-decompose) looked like N distinct agents to any peer
# reading ambient by alias alone.
#
# Call this on the first turn of a session, and again on any role-switch
# within the same shell (same session_id, new/changed alias).
#
# Usage:
#   scripts/coord/role-card-emit.sh --role <alias> --lane <LANE> \
#       [--claim <gap-id>] [--wake-mode cron|event-driven|manual] \
#       [--session-id <uuid>]
#
# Example:
#   scripts/coord/role-card-emit.sh --role curator-opus-target \
#       --lane EFFECTIVE --claim INFRA-2017 --wake-mode event-driven
#
# session_id resolution (must be the physical Claude Code session UUID,
# NOT the alias name — that's what makes dedup-by-session_id useful):
#   1. --session-id flag (explicit override)
#   2. CLAUDE_SESSION_ID env (Claude Code's real per-session UUID)
#   3. CHUMP_SESSION_ID env (fallback; may itself be alias-shaped on
#      older sessions, but is still the best available identity)
#
# Emits: kind=role_card with fields session_id, aliases (JSON array),
# primary_lane, active_claim, wake_mode.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

ROLE=""
LANE=""
CLAIM=""
WAKE_MODE="manual"
SESSION_ID_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)       ROLE="${2:-}"; shift 2 ;;
        --lane)       LANE="${2:-}"; shift 2 ;;
        --claim)      CLAIM="${2:-}"; shift 2 ;;
        --wake-mode)  WAKE_MODE="${2:-}"; shift 2 ;;
        --session-id) SESSION_ID_OVERRIDE="${2:-}"; shift 2 ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ -z "$ROLE" ]] || [[ -z "$LANE" ]]; then
    echo "Usage: role-card-emit.sh --role <alias> --lane <EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE|MISSION> [--claim <gap-id>] [--wake-mode cron|event-driven|manual] [--session-id <uuid>]" >&2
    exit 2
fi

case "$LANE" in
    EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE|MISSION) ;;
    *)
        echo "role-card-emit: --lane must be one of EFFECTIVE/CREDIBLE/RESILIENT/ZERO-WASTE/MISSION (got '$LANE')" >&2
        exit 2
        ;;
esac

SESSION_ID="${SESSION_ID_OVERRIDE:-${CLAUDE_SESSION_ID:-${CHUMP_SESSION_ID:-}}}"
if [[ -z "$SESSION_ID" ]]; then
    echo "role-card-emit: no session id available (set CLAUDE_SESSION_ID, CHUMP_SESSION_ID, or --session-id)" >&2
    exit 2
fi

ACTIVE_CLAIM="${CLAIM:-null}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

if [[ "$ACTIVE_CLAIM" == "null" ]]; then
    CLAIM_JSON="null"
else
    CLAIM_JSON="\"$ACTIVE_CLAIM\""
fi

printf '{"ts":"%s","kind":"role_card","session_id":"%s","aliases":["%s"],"primary_lane":"%s","active_claim":%s,"wake_mode":"%s"}\n' \
    "$TS" \
    "$SESSION_ID" \
    "$ROLE" \
    "$LANE" \
    "$CLAIM_JSON" \
    "$WAKE_MODE" \
    >> "$AMBIENT" 2>/dev/null || true

echo "role-card: emitted session_id=$SESSION_ID alias=$ROLE lane=$LANE claim=$ACTIVE_CLAIM wake_mode=$WAKE_MODE" >&2

exit 0
