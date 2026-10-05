#!/usr/bin/env bash
# scripts/dev/fix-trunk-signal-harness.sh — INFRA-4712 (INFRA-2342 slice)
#
# Standalone test harness: publishes a fix_trunk test signal to the global
# URGENT-INBOX queue (.chump-locks/URGENT-INBOX.jsonl) and logs the
# message ID + timestamp so the publish can be independently verified.
#
# Deliberately decoupled from scripts/dispatch/fix-trunk-dispatcher.sh
# (which only publishes as a side effect of a real trunk-red claim) — this
# exists so a human or CI test can exercise the URGENT-INBOX publish
# contract on demand, without needing a live trunk-red incident.
#
# Usage:
#   fix-trunk-signal-harness.sh [--gap-id ID] [--body TEXT]
#
# Env overrides (for hermetic tests):
#   CHUMP_URGENT_INBOX           override path to URGENT-INBOX.jsonl
#   CHUMP_FIX_TRUNK_HARNESS_LOG  override path to the harness's own log file
#
# Emits:
#   - one JSONL line to URGENT-INBOX with kind=fix_trunk_test_signal
#   - one JSONL line to the harness log with message_id + ts (verification trail)

set -euo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
URGENT_INBOX="${CHUMP_URGENT_INBOX:-$REPO_ROOT/.chump-locks/URGENT-INBOX.jsonl}"
HARNESS_LOG="${CHUMP_FIX_TRUNK_HARNESS_LOG:-$REPO_ROOT/.chump-locks/fix-trunk-signal-harness.log}"
mkdir -p "$(dirname "$URGENT_INBOX")" "$(dirname "$HARNESS_LOG")"

GAP_ID="TEST-GAP"
BODY="fix_trunk test signal published by fix-trunk-signal-harness.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gap-id)  GAP_ID="${2:-}"; shift 2 ;;
    --body)    BODY="${2:-}"; shift 2 ;;
    --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MSG_ID="fts-$(date +%s%N)-$$"

python3 -c "
import json, sys
entry = {
    'ts': sys.argv[1],
    'urgency': 'CRIT',
    'from': 'fix-trunk-signal-harness',
    'to': 'fleet-wide',
    'kind': 'fix_trunk_test_signal',
    'message_id': sys.argv[2],
    'gap_id': sys.argv[3],
    'body': sys.argv[4],
}
print(json.dumps(entry))
" "$TS" "$MSG_ID" "$GAP_ID" "$BODY" >> "$URGENT_INBOX"

printf '{"ts":"%s","message_id":"%s","gap_id":"%s","urgent_inbox":"%s"}\n' \
  "$TS" "$MSG_ID" "$GAP_ID" "$URGENT_INBOX" >> "$HARNESS_LOG"

echo "[fix-trunk-signal-harness] published message_id=$MSG_ID ts=$TS to $URGENT_INBOX"
echo "  verify: grep '$MSG_ID' \"$URGENT_INBOX\""
echo "  log:    $HARNESS_LOG"
