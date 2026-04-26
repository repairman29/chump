#!/usr/bin/env bash
# broadcast.sh — Structured agent-to-agent messaging via the ambient stream.
#
# Phase 1: dual-publishes to both ambient.jsonl (file-based, always) and
# NATS JetStream (chump.events.*, when chump-coord is available). Agents
# that haven't installed NATS yet continue to receive events via the file
# stream; NATS-connected agents get real-time fanout without polling.
#
# Usage:
#   scripts/coord/broadcast.sh INTENT  <gap-id> [file1,file2,...]
#   scripts/coord/broadcast.sh HANDOFF <gap-id> <to-session>
#   scripts/coord/broadcast.sh STUCK   <gap-id> "<reason>"
#   scripts/coord/broadcast.sh DONE    <gap-id> [commit-sha]
#   scripts/coord/broadcast.sh WARN    "<message>"
#   scripts/coord/broadcast.sh ALERT   kind=<kind> "<message>"
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
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"
EMIT_SCRIPT="$REPO_ROOT/scripts/dev/ambient-emit.sh"

# ── Resolve session ID ────────────────────────────────────────────────────────
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    _WT_CACHE="$LOCK_DIR/.wt-session-id"
    [[ -f "$_WT_CACHE" ]] && SESSION_ID="$(cat "$_WT_CACHE" 2>/dev/null || true)"
fi
if [[ -z "$SESSION_ID" && -f "$HOME/.chump/session_id" ]]; then
    SESSION_ID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi
SESSION_ID="${SESSION_ID:-broadcast-$$-$(date +%s)}"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Build JSON payload ────────────────────────────────────────────────────────
build_json() {
    python3 -c "import json,sys; print(json.dumps(dict(zip(sys.argv[1::2],sys.argv[2::2]))))" "$@"
}

# ── Write to ambient.jsonl (always — file-based fallback) ────────────────────
emit_to_file() {
    local json="$1"
    mkdir -p "$LOCK_DIR"
    if [[ -x "$EMIT_SCRIPT" ]]; then
        echo "$json" | "$EMIT_SCRIPT" 2>/dev/null && return
    fi
    local tmp
    tmp="$(mktemp "$LOCK_DIR/.broadcast_XXXXXX")"
    printf '%s\n' "$json" >> "$tmp"
    cat "$tmp" >> "$AMBIENT"
    rm -f "$tmp"
}

# ── Publish to NATS JetStream (Phase 1 — when chump-coord available) ─────────
emit_to_nats() {
    local event_type="$1"
    shift
    local coord_bin
    coord_bin="$(command -v chump-coord 2>/dev/null || true)"
    [[ -n "$coord_bin" ]] || return 0
    # Build key=value args from remaining positional pairs
    CHUMP_SESSION_ID="$SESSION_ID" "$coord_bin" emit "$event_type" "$@" 2>/dev/null || true
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
        emit_to_file "$JSON"
        emit_to_nats INTENT "gap=$GAP" "files=$FILES"
        printf '[broadcast] INTENT  session=%s  gap=%s\n' "$SESSION_ID" "$GAP"
        ;;

    HANDOFF)
        GAP="${1:-}"; TO="${2:-}"
        [[ -n "$GAP" && -n "$TO" ]] || { echo "Usage: $0 HANDOFF <gap-id> <to-session>" >&2; exit 1; }
        JSON="$(build_json event HANDOFF session "$SESSION_ID" ts "$TS" gap "$GAP" to "$TO")"
        emit_to_file "$JSON"
        emit_to_nats HANDOFF "gap=$GAP" "to=$TO"
        printf '[broadcast] HANDOFF gap=%s → %s\n' "$GAP" "$TO"
        ;;

    STUCK)
        GAP="${1:-}"; REASON="${2:-unspecified}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 STUCK <gap-id> \"<reason>\"" >&2; exit 1; }
        JSON="$(build_json event STUCK session "$SESSION_ID" ts "$TS" gap "$GAP" reason "$REASON")"
        emit_to_file "$JSON"
        emit_to_nats STUCK "gap=$GAP" "reason=$REASON"
        printf '[broadcast] STUCK   gap=%s  reason=%s\n' "$GAP" "$REASON"
        ;;

    DONE)
        GAP="${1:-}"; COMMIT="${2:-}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 DONE <gap-id> [commit-sha]" >&2; exit 1; }
        JSON="$(build_json event DONE session "$SESSION_ID" ts "$TS" gap "$GAP" commit "$COMMIT")"
        emit_to_file "$JSON"
        emit_to_nats DONE "gap=$GAP" "commit=$COMMIT"
        printf '[broadcast] DONE    gap=%s  commit=%s\n' "$GAP" "$COMMIT"
        ;;

    WARN)
        MSG="${1:-}"
        [[ -n "$MSG" ]] || { echo "Usage: $0 WARN \"<message>\"" >&2; exit 1; }
        JSON="$(build_json event WARN session "$SESSION_ID" ts "$TS" reason "$MSG")"
        emit_to_file "$JSON"
        emit_to_nats WARN "reason=$MSG"
        printf '[broadcast] WARN    %s\n' "$MSG"
        ;;

    ALERT)
        KIND_ARG="${1:-}"; MSG="${2:-}"
        KIND="${KIND_ARG#kind=}"
        [[ -n "$KIND" ]] || { echo "Usage: $0 ALERT kind=<kind> \"<message>\"" >&2; exit 1; }
        JSON="$(build_json event ALERT session "$SESSION_ID" ts "$TS" kind "$KIND" reason "$MSG")"
        emit_to_file "$JSON"
        emit_to_nats ALERT "kind=$KIND" "reason=$MSG"
        printf '[broadcast] ALERT   kind=%s  %s\n' "$KIND" "$MSG"
        ;;

    *)
        echo "Unknown event type: $EVENT" >&2
        echo "Valid types: INTENT HANDOFF STUCK DONE WARN ALERT" >&2
        exit 1
        ;;
esac
