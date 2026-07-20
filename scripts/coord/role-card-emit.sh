#!/usr/bin/env bash
# scripts/coord/role-card-emit.sh — INFRA-2017 (RCA Change 2 follow-up)
#
# Emits kind=role_card to ambient.jsonl on a curator session's first turn
# (and on any role-switch within the same shell). A single physical Claude
# Code session can inhabit multiple curator aliases across a shift — this
# event lets peers dedupe dispatch decisions by session_id (the physical
# session) rather than alias-name, which is the RCA Change 2 collision
# class this gap closes.
#
# Usage:
#   scripts/coord/role-card-emit.sh --role <alias> --lane <PILLAR> \
#       [--claim <gap-id>] [--wake-mode cron|event-driven|manual]
#
# Example:
#   scripts/coord/role-card-emit.sh --role curator-opus-target \
#       --lane EFFECTIVE --claim INFRA-2017 --wake-mode event-driven
#
# session_id is auto-detected from CHUMP_SESSION_ID / CLAUDE_SESSION_ID
# (the Claude Code session UUID) — never the alias name. Repeated calls
# within the same shell with a different --role accumulate into the
# `aliases` list emitted on the NEXT call (role-switch case); each call
# still emits its own event so role-card-query.sh can build the latest
# aliases set per session_id by scanning the tail.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

ROLE=""
LANE=""
CLAIM="null"
WAKE_MODE="manual"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)      ROLE="${2:-}"; shift 2 ;;
        --lane)      LANE="${2:-}"; shift 2 ;;
        --claim)     CLAIM="${2:-}"; shift 2 ;;
        --wake-mode) WAKE_MODE="${2:-}"; shift 2 ;;
        --help|-h)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ -z "$ROLE" ]] || [[ -z "$LANE" ]]; then
    echo "Usage: role-card-emit.sh --role <alias> --lane <EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE|MISSION> [--claim <gap-id>] [--wake-mode cron|event-driven|manual]" >&2
    exit 2
fi

case "$LANE" in
    EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE|MISSION) ;;
    *)
        echo "[role-card-emit] ERROR: --lane must be one of EFFECTIVE/CREDIBLE/RESILIENT/ZERO-WASTE/MISSION (got '$LANE')" >&2
        exit 2
        ;;
esac

case "$WAKE_MODE" in
    cron|event-driven|manual) ;;
    *)
        echo "[role-card-emit] ERROR: --wake-mode must be one of cron/event-driven/manual (got '$WAKE_MODE')" >&2
        exit 2
        ;;
esac

SESSION="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-session-$$}}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Accumulate the alias list for this physical session across role-switches
# within the same shell (RCA Change 2: one session, many aliases).
ALIASES_STATE_DIR="$REPO_ROOT/.chump-locks/role-cards"
mkdir -p "$ALIASES_STATE_DIR" 2>/dev/null || true
ALIASES_STATE_FILE="$ALIASES_STATE_DIR/${SESSION}.aliases"

if [[ -f "$ALIASES_STATE_FILE" ]]; then
    EXISTING="$(cat "$ALIASES_STATE_FILE" 2>/dev/null || true)"
else
    EXISTING=""
fi

IFS=',' read -r -a ALIAS_ARR <<<"$EXISTING"
FOUND=0
for a in "${ALIAS_ARR[@]:-}"; do
    [[ "$a" == "$ROLE" ]] && FOUND=1
done
if [[ "$FOUND" -eq 0 ]]; then
    if [[ -z "$EXISTING" ]]; then
        NEW_ALIASES="$ROLE"
    else
        NEW_ALIASES="${EXISTING},${ROLE}"
    fi
else
    NEW_ALIASES="$EXISTING"
fi
printf '%s' "$NEW_ALIASES" > "$ALIASES_STATE_FILE" 2>/dev/null || true

# Build JSON aliases array from the comma-separated accumulation.
ALIASES_JSON="$(printf '%s' "$NEW_ALIASES" | awk -F',' '{
    printf "["
    for (i = 1; i <= NF; i++) {
        printf "\"%s\"", $i
        if (i < NF) printf ","
    }
    printf "]"
}')"

if [[ "$CLAIM" == "null" || -z "$CLAIM" ]]; then
    CLAIM_JSON="null"
else
    CLAIM_JSON="\"${CLAIM}\""
fi

mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

printf '{"ts":"%s","kind":"role_card","session_id":"%s","aliases":%s,"primary_lane":"%s","active_claim":%s,"wake_mode":"%s"}\n' \
    "$TS" \
    "$SESSION" \
    "$ALIASES_JSON" \
    "$LANE" \
    "$CLAIM_JSON" \
    "$WAKE_MODE" \
    >> "$AMBIENT" 2>/dev/null || true

echo "role-card: emitted for session=$SESSION role=$ROLE lane=$LANE aliases=$NEW_ALIASES" >&2

exit 0
