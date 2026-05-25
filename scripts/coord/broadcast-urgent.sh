#!/usr/bin/env bash
# scripts/coord/broadcast-urgent.sh — INFRA-2016
#
# Send a CRIT or EMERGENCY message to the GLOBAL urgent inbox so
# EVERY agent's PostToolUse hook surfaces it (via inbox-check-urgent.sh)
# regardless of session-keyed inbox routing.
#
# This is the explicit "must-be-seen" path. Use sparingly — every CRIT
# message interrupts every agent in the repo on their next tool call.
#
# Usage:
#   broadcast-urgent.sh --urgency CRIT|EMERGENCY \
#       [--to <recipient>|fleet-wide] [--from <sender>] \
#       "<body text>"
#
# Examples:
#   broadcast-urgent.sh --urgency CRIT "trunk-RED on PR #2593 — all workers pivot to triage"
#   broadcast-urgent.sh --urgency EMERGENCY --to all "stale-base force-push detected on PR #2582 — STOP all pushes"
#
# Companion: scripts/coord/inbox-check-urgent.sh (PostToolUse hook reader)
# Companion: scripts/coord/broadcast.sh (session-keyed normal A2A)

set -euo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
URGENT_INBOX="$REPO_ROOT/.chump-locks/URGENT-INBOX.jsonl"
mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true

URGENCY=""
TO="fleet-wide"
FROM="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-wizard-or-unknown}}"
BODY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --urgency) URGENCY="${2:-}"; shift 2 ;;
        --to)      TO="${2:-fleet-wide}"; shift 2 ;;
        --from)    FROM="${2:-}"; shift 2 ;;
        --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
        *)         BODY="$1"; shift ;;
    esac
done

case "$URGENCY" in
    CRIT|EMERGENCY) ;;
    "")
        echo "ERROR: --urgency required (CRIT or EMERGENCY)" >&2
        echo "For lower urgency, use: scripts/coord/broadcast.sh" >&2
        exit 2
        ;;
    *)
        echo "ERROR: --urgency must be CRIT or EMERGENCY (got: $URGENCY)" >&2
        exit 2
        ;;
esac

[[ -z "$BODY" ]] && { echo "ERROR: message body required" >&2; exit 2; }

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Append to global urgent inbox as one JSON line (escape via python for safety)
python3 -c "
import json
entry = {
    'ts': '$TS',
    'urgency': '$URGENCY',
    'from': '''$FROM''',
    'to': '''$TO''',
    'body': '''$BODY''',
}
print(json.dumps(entry))
" >> "$URGENT_INBOX"

# Audit emit
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
printf '{"ts":"%s","kind":"urgent_broadcast_sent","source":"broadcast_urgent","urgency":"%s","from":"%s","to":"%s"}\n' \
    "$TS" "$URGENCY" "$FROM" "$TO" \
    >> "$AMBIENT" 2>/dev/null || true

echo "[broadcast-urgent] $URGENCY from=$FROM to=$TO ts=$TS"
echo "  delivered to: $URGENT_INBOX"
echo "  agents will see it on their next PostToolUse hook (within ~1 tool call)"
echo "  audit: grep urgent_broadcast_sent .chump-locks/ambient.jsonl | tail -1"
