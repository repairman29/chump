#!/usr/bin/env bash
# broadcast.sh — Structured agent-to-agent messaging via the ambient stream.
#
# Phase 1: dual-publishes to both ambient.jsonl (file-based, always) and
# NATS JetStream (chump.events.*, when chump-coord is available). Agents
# that haven't installed NATS yet continue to receive events via the file
# stream; NATS-connected agents get real-time fanout without polling.
#
# INFRA-1115 (mailboxes): every event type now accepts a leading
# --to <recipient-session-id> flag. When set, the event is ALSO appended
# to .chump-locks/inbox/<recipient>.jsonl so the recipient can read
# targeted messages without scanning the whole ambient stream.
# Glob recipients (e.g. --to fleet-worker-*) expand at send-time against
# live session lease files in .chump-locks/.
#
# Usage:
#   scripts/coord/broadcast.sh [--to <recipient>] INTENT  <gap-id> [file1,file2,...]
#   scripts/coord/broadcast.sh [--to <recipient>] HANDOFF <gap-id> <to-session>
#   scripts/coord/broadcast.sh [--to <recipient>] STUCK   <gap-id> "<reason>"
#   scripts/coord/broadcast.sh [--to <recipient>] DONE    <gap-id> [commit-sha]
#   scripts/coord/broadcast.sh [--to <recipient>] WARN    "<message>"
#   scripts/coord/broadcast.sh [--to <recipient>] ALERT   kind=<kind> "<message>"
#
# Event schema (all events):
#   event    — one of: INTENT HANDOFF STUCK DONE WARN ALERT
#   session  — sender's session ID
#   ts       — ISO-8601 UTC timestamp
#   gap      — gap ID (when applicable)
#   files    — comma-separated file paths (INTENT only)
#   to       — recipient session (HANDOFF, or any event with --to)
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
# CREDIBLE-025: include worker model in all events so per-model stats are attributable.
MODEL="${FLEET_MODEL:-${CHUMP_MODEL:-unknown}}"
# CREDIBLE-037: include harness attribution in all events so per-harness stats are attributable.
HARNESS="${CHUMP_AGENT_HARNESS:-unknown}"

# INFRA-1255: correlation_id ties INTENT/STUCK/HANDOFF (the "request" side)
# to DONE/ACK (the "response" side). When events share a corr_id, inbox-reap
# can clear the inbox on completion. Default precedence:
#   --corr <id>  >  gap-id (when applicable)  >  current branch  >  ts
# Callers can pass --corr to override; otherwise the per-event handler
# auto-derives. Set CHUMP_CORR_ID in env to force across nested calls.
CORR_ID_OVERRIDE="${CHUMP_CORR_ID:-}"

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

# INFRA-1115: write the JSON event into the recipient session's inbox.
# Concurrent-append safety via flock; max wait 5s before fallback to
# ambient-only with WARN.
emit_to_inbox() {
    local recipient="$1" json="$2"
    [[ -n "$recipient" ]] || return 0
    local inbox_dir="$LOCK_DIR/inbox"
    mkdir -p "$inbox_dir" 2>/dev/null || true
    # Glob recipient: expand against live session leases. A glob is any
    # recipient containing one of [*?[]. Non-glob → single recipient list.
    local recipients=()
    if [[ "$recipient" == *[*?[]* ]]; then
        local pattern="${recipient}"
        # Match against .chump-locks/<session>.json filenames.
        shopt -s nullglob
        local matches=()
        for f in "$LOCK_DIR"/*.json; do
            local base
            base="$(basename "$f" .json)"
            # Skip non-session JSON files (e.g. fleet-state.json).
            [[ "$base" == fleet-state || "$base" == health-* ]] && continue
            # shellcheck disable=SC2053
            if [[ "$base" == $pattern ]]; then
                matches+=("$base")
            fi
        done
        shopt -u nullglob
        recipients=("${matches[@]}")
        if [[ ${#recipients[@]} -eq 0 ]]; then
            printf '[broadcast] WARN: --to %s expanded to 0 live sessions\n' "$recipient" >&2
            return 0
        fi
    else
        recipients=("$recipient")
    fi
    local r lock_file
    for r in "${recipients[@]}"; do
        local inbox_file="$inbox_dir/$r.jsonl"
        lock_file="$inbox_dir/.$r.lock"
        if command -v flock >/dev/null 2>&1; then
            (
                exec 200>"$lock_file"
                if flock -w 5 200; then
                    printf '%s\n' "$json" >> "$inbox_file"
                else
                    printf '[broadcast] WARN: could not lock inbox %s within 5s; skipping inbox write (ambient retained)\n' "$inbox_file" >&2
                fi
            )
        else
            # No flock available — best-effort append. Single-machine fleets
            # with one process per session rarely race here.
            printf '%s\n' "$json" >> "$inbox_file"
        fi
    done
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--to <recipient>] INTENT|HANDOFF|STUCK|DONE|WARN|ALERT [args...]" >&2
    exit 1
fi

# INFRA-1115: optional --to <recipient> targets the inbox(es) named.
# INFRA-1255: optional --corr <id> sets correlation_id explicitly.
# Both flags can appear in either order before the event-type positional.
TO=""
CORR_FLAG=""
while :; do
    case "${1:-}" in
        --to)
            TO="${2:-}"
            [[ -z "$TO" ]] && { echo "Usage: $0 --to <recipient> EVENT [args...]" >&2; exit 1; }
            shift 2
            ;;
        --corr)
            CORR_FLAG="${2:-}"
            [[ -z "$CORR_FLAG" ]] && { echo "Usage: $0 --corr <id> EVENT [args...]" >&2; exit 1; }
            shift 2
            ;;
        *) break ;;
    esac
done

EVENT="$1"
shift

# INFRA-1255: corr_id derivation. Precedence: --corr flag > env > gap-id (set
# per-event below) > branch name > ts. Per-event handlers set CORR_ID after
# they parse their own gap argument.
_derive_corr() {
    local from_gap="${1:-}"
    if [[ -n "$CORR_FLAG" ]]; then echo "$CORR_FLAG"; return; fi
    if [[ -n "$CORR_ID_OVERRIDE" ]]; then echo "$CORR_ID_OVERRIDE"; return; fi
    if [[ -n "$from_gap" ]]; then echo "$from_gap"; return; fi
    local br
    br="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [[ -n "$br" && "$br" != "HEAD" ]]; then echo "branch:$br"; return; fi
    echo "ts:$TS"
}

case "$EVENT" in

    INTENT)
        GAP="${1:-}"
        FILES="${2:-}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 INTENT <gap-id> [files]" >&2; exit 1; }
        CORR_ID="$(_derive_corr "$GAP")"
        if [[ -n "$TO" ]]; then
            JSON="$(build_json event INTENT session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" gap "$GAP" files "$FILES" to "$TO" model "$MODEL" harness "$HARNESS")"
        else
            JSON="$(build_json event INTENT session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" gap "$GAP" files "$FILES" model "$MODEL" harness "$HARNESS")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        emit_to_nats INTENT "gap=$GAP" "files=$FILES" "model=$MODEL" "harness=$HARNESS"
        printf '[broadcast] INTENT  session=%s  gap=%s\n' "$SESSION_ID" "$GAP"
        ;;

    HANDOFF)
        GAP="${1:-}"; POS_TO="${2:-}"
        # Back-compat: HANDOFF accepts the recipient as positional arg 2. If
        # --to was also given, --to wins; otherwise the positional value is
        # used as both the JSON "to" field AND the inbox target.
        EFFECTIVE_TO="${TO:-$POS_TO}"
        [[ -n "$GAP" && -n "$EFFECTIVE_TO" ]] || { echo "Usage: $0 [--to <recipient>] HANDOFF <gap-id> [<to-session>]" >&2; exit 1; }
        CORR_ID="$(_derive_corr "$GAP")"
        JSON="$(build_json event HANDOFF session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" gap "$GAP" to "$EFFECTIVE_TO")"
        emit_to_file "$JSON"
        emit_to_inbox "$EFFECTIVE_TO" "$JSON"
        emit_to_nats HANDOFF "gap=$GAP" "to=$EFFECTIVE_TO"
        printf '[broadcast] HANDOFF gap=%s → %s\n' "$GAP" "$EFFECTIVE_TO"
        ;;

    STUCK)
        GAP="${1:-}"; REASON="${2:-unspecified}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 STUCK <gap-id> \"<reason>\"" >&2; exit 1; }
        CORR_ID="$(_derive_corr "$GAP")"
        if [[ -n "$TO" ]]; then
            JSON="$(build_json event STUCK session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" gap "$GAP" reason "$REASON" to "$TO")"
        else
            JSON="$(build_json event STUCK session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" gap "$GAP" reason "$REASON")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        emit_to_nats STUCK "gap=$GAP" "reason=$REASON"
        printf '[broadcast] STUCK   gap=%s  reason=%s\n' "$GAP" "$REASON"
        ;;

    DONE)
        GAP="${1:-}"; COMMIT="${2:-}"
        [[ -n "$GAP" ]] || { echo "Usage: $0 DONE <gap-id> [commit-sha]" >&2; exit 1; }
        CORR_ID="$(_derive_corr "$GAP")"
        if [[ -n "$TO" ]]; then
            JSON="$(build_json event DONE session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" gap "$GAP" commit "$COMMIT" to "$TO" model "$MODEL" harness "$HARNESS")"
        else
            JSON="$(build_json event DONE session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" gap "$GAP" commit "$COMMIT" model "$MODEL" harness "$HARNESS")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        emit_to_nats DONE "gap=$GAP" "commit=$COMMIT" "model=$MODEL" "harness=$HARNESS"
        printf '[broadcast] DONE    gap=%s  commit=%s\n' "$GAP" "$COMMIT"
        ;;

    WARN)
        MSG="${1:-}"
        [[ -n "$MSG" ]] || { echo "Usage: $0 WARN \"<message>\"" >&2; exit 1; }
        CORR_ID="$(_derive_corr "")"
        if [[ -n "$TO" ]]; then
            JSON="$(build_json event WARN session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" reason "$MSG" to "$TO")"
        else
            JSON="$(build_json event WARN session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" reason "$MSG")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        emit_to_nats WARN "reason=$MSG"
        printf '[broadcast] WARN    %s\n' "$MSG"
        ;;

    ALERT)
        KIND_ARG="${1:-}"; MSG="${2:-}"
        KIND="${KIND_ARG#kind=}"
        [[ -n "$KIND" ]] || { echo "Usage: $0 ALERT kind=<kind> \"<message>\"" >&2; exit 1; }
        CORR_ID="$(_derive_corr "")"
        if [[ -n "$TO" ]]; then
            JSON="$(build_json event ALERT session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" kind "$KIND" reason "$MSG" to "$TO")"
        else
            JSON="$(build_json event ALERT session "$SESSION_ID" ts "$TS" corr_id "$CORR_ID" kind "$KIND" reason "$MSG")"
        fi
        emit_to_file "$JSON"
        emit_to_inbox "$TO" "$JSON"
        emit_to_nats ALERT "kind=$KIND" "reason=$MSG"
        printf '[broadcast] ALERT   kind=%s  %s\n' "$KIND" "$MSG"
        ;;

    *)
        echo "Unknown event type: $EVENT" >&2
        echo "Valid types: INTENT HANDOFF STUCK DONE WARN ALERT" >&2
        exit 1
        ;;
esac
