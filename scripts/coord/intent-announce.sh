#!/usr/bin/env bash
# intent-announce.sh — Emit INTENT for the current session (INFRA-1116).
#
# Wraps broadcast.sh INTENT so callers don't have to remember the arg order
# AND so we can later compose with mailbox routing / signed envelopes
# without changing call sites.
#
# Usage:
#   intent-announce.sh <gap-id> [<paths-csv>]
#
# Returns 0 always (best-effort). Failure to emit INTENT is logged to
# stderr but does NOT block the caller — better to ship work than fail
# on a non-load-bearing telemetry write.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROADCAST="$SCRIPT_DIR/broadcast.sh"

[[ $# -ge 1 ]] || { echo "Usage: $0 <gap-id> [<paths-csv>]" >&2; exit 2; }
GAP_ID="$1"
PATHS="${2:-}"

if [[ -x "$BROADCAST" ]]; then
    "$BROADCAST" INTENT "$GAP_ID" "$PATHS" >/dev/null 2>&1 || \
        echo "[intent-announce] WARN: broadcast.sh INTENT $GAP_ID failed (non-fatal)" >&2
else
    echo "[intent-announce] WARN: $BROADCAST not executable; INTENT not announced" >&2
fi
exit 0
