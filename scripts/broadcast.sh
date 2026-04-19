#!/usr/bin/env bash
# broadcast.sh — Structured agent-to-agent messaging via the ambient stream.
#
# Writes typed events to .chump-locks/ambient.jsonl that all other sessions
# can read in real time (via ambient-watch.sh or by tailing the file).
#
# Usage:
#   scripts/broadcast.sh INTENT  <gap-id> [file1,file2,...]
#   scripts/broadcast.sh HANDOFF <gap-id> <to-session>
#   scripts/broadcast.sh STUCK   <gap-id> "<reason>"
#   scripts/broadcast.sh DONE    <gap-id> [commit-sha]
#   scripts/broadcast.sh WARN    "<message>"
#   scripts/broadcast.sh ALERT   kind=<kind> "<message>"
#
# Event schema (all events):
#   event    — one of: INTENT HANDOFF STUCK DONE WARN ALERT
#   session  — sender's session ID
#   ts       — ISO-8601 UTC timestamp
#   gap      — gap ID (when applicable)
#   files    — comma-separated file paths (INTENT only)
#   to       — recipient session (HANDOFF only)
#   reason   — free-form note (STUCK, WARN, ALERT)
#   commit   — sha (DONE only)
#   kind     — alert sub-type (ALERT only)
#
# Agents should check ambient.jsonl for INTENT events from the last 5 minutes
# before claiming a gap. If another session announced INTENT for the same gap,
# pause 10 seconds and re-check before proceeding.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"
EMIT_SCRIPT="$REPO_ROOT/scripts/ambient-emit.sh"

# ── Resolve session ID (mirrors gap-claim.sh priority order) ─────────────────
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    _WT_CACHE="$LOCK_DIR/.wt-session-id"
    [[ -f "$_WT_CACHE" ]] && SESSION_ID="$(cat "$_WT_CACHE" 2>/dev/null || true)"
fi
if [[ -z "$SESSION_ID" && -f "$HOME/.chump/session_id" ]]; then
    SESSION_ID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="broadcast-$$-$(date +%s)"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Write a JSON line atomically (write to tmp, then mv to avoid torn reads).
emit_line() {
    local json="$1"
    mkdir -p "$LOCK_DIR"

    # Try the repo's own ambient-emit.sh first (handles locking correctly).
    if [[ -x "$EMIT_SCRIPT" ]]; then
        echo "$json" | "$EMIT_SCRIPT" 2>/dev/null && return
    fi

    # Fallback: atomic write directly.
    local tmp
    tmp="$(mktemp "$LOCK_DIR/.ambient_emit_XXXXXX")"
    printf '%s\n' "$json" >> "$tmp"
    cat "$tmp" >> "$AMBIENT"
    rm -f "$tmp"
}

build_json() {
    python3 -c "import json,sys; print(json.dumps(dict(zip(sys.argv[1::2],sys.argv[2::2]))))" "$@"
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 INTENT|HANDOFF|STUCK|DONE|WARN|ALERT [args...]" >&2
    exit 1
fi

EVENT="$1"
shift

case "$EVENT" in

    INTENT)
        GAP="${1:-}"
        FILES="${2:-}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 INTENT <gap-id> [files]" >&2; exit 1; }
        JSON="$(build_json event INTENT session "$SESSION_ID" ts "$TS" gap "$GAP" files "$FILES")"
        emit_line "$JSON"
        printf '[broadcast] INTENT  session=%s  gap=%s\n' "$SESSION_ID" "$GAP"
        ;;

    HANDOFF)
        GAP="${1:-}"
        TO="${2:-}"
        [[ -n "$GAP" && -n "$TO" ]] || { echo "Usage: $0 HANDOFF <gap-id> <to-session>" >&2; exit 1; }
        JSON="$(build_json event HANDOFF session "$SESSION_ID" ts "$TS" gap "$GAP" to "$TO")"
        emit_line "$JSON"
        printf '[broadcast] HANDOFF gap=%s → %s\n' "$GAP" "$TO"
        ;;

    STUCK)
        GAP="${1:-}"
        REASON="${2:-unspecified}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 STUCK <gap-id> \"<reason>\"" >&2; exit 1; }
        JSON="$(build_json event STUCK session "$SESSION_ID" ts "$TS" gap "$GAP" reason "$REASON")"
        emit_line "$JSON"
        printf '[broadcast] STUCK   gap=%s  reason=%s\n' "$GAP" "$REASON"
        ;;

    DONE)
        GAP="${1:-}"
        COMMIT="${2:-}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 DONE <gap-id> [commit-sha]" >&2; exit 1; }
        JSON="$(build_json event DONE session "$SESSION_ID" ts "$TS" gap "$GAP" commit "$COMMIT")"
        emit_line "$JSON"
        printf '[broadcast] DONE    gap=%s  commit=%s\n' "$GAP" "$COMMIT"
        ;;

    WARN)
        MSG="${1:-}"
        [[ -n "$MSG" ]] || { echo "Usage: $0 WARN \"<message>\"" >&2; exit 1; }
        JSON="$(build_json event WARN session "$SESSION_ID" ts "$TS" reason "$MSG")"
        emit_line "$JSON"
        printf '[broadcast] WARN    %s\n' "$MSG"
        ;;

    ALERT)
        # ALERT kind=<kind> "<message>"
        KIND_ARG="${1:-}"
        MSG="${2:-}"
        KIND="${KIND_ARG#kind=}"
        [[ -n "$KIND" ]] || { echo "Usage: $0 ALERT kind=<kind> \"<message>\"" >&2; exit 1; }
        JSON="$(build_json event ALERT session "$SESSION_ID" ts "$TS" kind "$KIND" reason "$MSG")"
        emit_line "$JSON"
        printf '[broadcast] ALERT   kind=%s  %s\n' "$KIND" "$MSG"
        ;;

    *)
        echo "Unknown event type: $EVENT" >&2
        echo "Valid types: INTENT HANDOFF STUCK DONE WARN ALERT" >&2
        exit 1
        ;;
esac
