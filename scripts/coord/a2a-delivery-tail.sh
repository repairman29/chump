#!/usr/bin/env bash
# a2a-delivery-tail.sh — poll ambient.jsonl for a delivery receipt (INFRA-1944).
#
# Slice A of INFRA-1862: broadcast.sh sends a message with a corr_id;
# chump-inbox.sh emits kind=a2a_msg_delivered when the recipient reads it.
# This script closes the loop — a sender (or anyone) can check whether a
# specific corr_id was delivered within a timeout window.
#
# Usage:
#   scripts/coord/a2a-delivery-tail.sh --corr-id <id> [--timeout <seconds>]
#
# Exit codes:
#   0 — kind=a2a_msg_delivered with matching corr_id found within timeout
#   1 — timeout elapsed with no matching delivery event
#   2 — usage error
#
# --timeout defaults to CHUMP_A2A_DELIVERY_TIMEOUT or 30s. A timeout of 0
# performs a single immediate check (no polling).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
LOCK_DIR="${LOCK_DIR:-$MAIN_REPO/.chump-locks}"
AMBIENT="$LOCK_DIR/ambient.jsonl"

CORR_ID=""
TIMEOUT="${CHUMP_A2A_DELIVERY_TIMEOUT:-30}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --corr-id)
            CORR_ID="${2:-}"
            shift 2
            ;;
        --timeout)
            TIMEOUT="${2:-}"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --corr-id <id> [--timeout <seconds>]" >&2
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

[[ -n "$CORR_ID" ]] || { echo "Usage: $0 --corr-id <id> [--timeout <seconds>]" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo "Usage: $0 --corr-id <id> [--timeout <seconds>]" >&2; exit 2; }

check_delivered() {
    [[ -f "$AMBIENT" ]] || return 1
    python3 -c "
import json, sys
corr_id = sys.argv[1]
path = sys.argv[2]
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            evt = json.loads(line)
        except Exception:
            continue
        if evt.get('kind') == 'a2a_msg_delivered' and evt.get('corr_id') == corr_id:
            sys.exit(0)
sys.exit(1)
" "$CORR_ID" "$AMBIENT"
}

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while true; do
    if check_delivered; then
        exit 0
    fi
    [[ "$(date +%s)" -ge "$DEADLINE" ]] && break
    sleep 1
done
exit 1
