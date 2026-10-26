#!/usr/bin/env bash
# scripts/dev/rca-ack-status.sh — INFRA-2018
#
# Lists active curator/worker sessions vs `.chump-locks/acks/*_<date>.json`
# acknowledgement receipts for a given RCA date-stamp (default: 2026-05-24).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCKS_DIR="${CHUMP_LOCKS_DIR:-$REPO_ROOT/.chump-locks}"
ACKS_DIR="$LOCKS_DIR/acks"
DATE_STAMP="${1:-2026-05-24}"

mkdir -p "$ACKS_DIR"

echo "=== RCA Ack Status ($DATE_STAMP) ==="
ack_count=0
shopt -s nullglob
for f in "$ACKS_DIR"/*_"${DATE_STAMP}".json; do
  ack_count=$((ack_count + 1))
  sid="$(basename "$f" "_${DATE_STAMP}.json")"
  echo "  [ACKED] $sid ($f)"
done

if [ "$ack_count" -eq 0 ]; then
  echo "  (no acks recorded yet — run: chump ack-rca $DATE_STAMP --note \"read and applied\")"
fi
exit 0
