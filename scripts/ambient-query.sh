#!/usr/bin/env bash
# ambient-query.sh — efficient grep helper for the peripheral-vision stream
#
# Searches .chump-locks/ambient.jsonl for events of a given kind, optionally
# filtered to the last N hours. Uses grep -m50 to cap results and avoids
# loading the whole file into memory.
#
# Usage:
#   scripts/ambient-query.sh <kind> [--since Nh]
#
# Examples:
#   scripts/ambient-query.sh ALERT
#   scripts/ambient-query.sh file_edit --since 1h
#   scripts/ambient-query.sh commit --since 24h
#   scripts/ambient-query.sh session_start --since 2h
#
# Arguments:
#   <kind>       Event kind to search for (e.g. ALERT, file_edit, commit,
#                bash_call, session_start, rotated). Case-sensitive.
#   --since Nh   Only show events from the last N hours (integer N required).
#
# Output:
#   Matching JSON lines, newest last, capped at 50 results.
#
# Environment:
#   CHUMP_AMBIENT_LOG   override the log path (default: <repo>/.chump-locks/ambient.jsonl)
#   AMBIENT_QUERY_LIMIT max results to return (default: 50)

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <kind> [--since Nh]" >&2
    echo "Examples:" >&2
    echo "  $0 ALERT" >&2
    echo "  $0 file_edit --since 1h" >&2
    echo "  $0 commit --since 24h" >&2
    exit 1
fi

EVENT_KIND="$1"
shift

SINCE_HOURS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since)
            shift
            if [[ $# -eq 0 ]]; then
                echo "[ambient-query] ERROR: --since requires an argument like '1h' or '24h'" >&2
                exit 1
            fi
            SINCE_HOURS="${1%h}"  # strip trailing 'h'
            if ! [[ "$SINCE_HOURS" =~ ^[0-9]+$ ]]; then
                echo "[ambient-query] ERROR: --since argument must be an integer number of hours (e.g. '1h', '24h')" >&2
                exit 1
            fi
            shift
            ;;
        *)
            echo "[ambient-query] ERROR: Unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
LIMIT="${AMBIENT_QUERY_LIMIT:-50}"

if [[ ! -f "$AMBIENT_LOG" ]]; then
    echo "[ambient-query] No ambient log found at $AMBIENT_LOG" >&2
    exit 0
fi

# ── Fast path: grep -m<LIMIT> caps results without reading the whole file ─────
# We grep for the event kind as a JSON field value.  The pattern
# '"event":"<kind>"' is reliable because ambient-emit.sh always produces
# that field at a fixed position in the JSON line.
GREP_PATTERN="\"event\":\"${EVENT_KIND}\""

if [[ -z "$SINCE_HOURS" ]]; then
    # No time filter — grep directly, cap at LIMIT
    grep -m"${LIMIT}" -- "$GREP_PATTERN" "$AMBIENT_LOG" || true
else
    # Time-filtered path: compute cutoff, pipe through python for ISO-8601
    # comparison, still cap at LIMIT.
    SINCE_HOURS_VAL="$SINCE_HOURS"
    python3 - "$AMBIENT_LOG" "$GREP_PATTERN" "$SINCE_HOURS_VAL" "$LIMIT" <<'PYEOF'
import sys, json, datetime

log_path    = sys.argv[1]
pattern     = sys.argv[2]
since_hours = int(sys.argv[3])
limit       = int(sys.argv[4])

cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=since_hours)

def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

count = 0
with open(log_path) as f:
    for line in f:
        stripped = line.rstrip("\n")
        if not stripped:
            continue
        # Quick substring check before full JSON parse (performance guard)
        if pattern not in stripped:
            continue
        try:
            ev = json.loads(stripped)
        except Exception:
            continue
        ts = parse_ts(ev.get("ts", ""))
        if ts is not None and ts < cutoff:
            continue
        print(stripped)
        count += 1
        if count >= limit:
            break
PYEOF
fi
