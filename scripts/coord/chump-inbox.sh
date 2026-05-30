#!/usr/bin/env bash
# chump-inbox.sh — Read targeted messages from a session's inbox (INFRA-1115).
#
# The inbox is .chump-locks/inbox/<session>.jsonl, a JSONL file written by
# broadcast.sh when called with --to <session>. A per-session cursor file
# .chump-locks/inbox/<session>.cursor stores the last-read byte offset so
# repeat reads only surface new messages.
#
# Usage:
#   chump-inbox.sh read [--since cursor|all|<iso-ts>] [--filter kind=X,from=Y]
#                       [--json] [--no-advance] [--session <id>]
#   chump-inbox.sh count [--session <id>]
#   chump-inbox.sh tail [--session <id>]
#
# Defaults: --session resolves the same way broadcast.sh does (CHUMP_SESSION_ID
# env, then .chump-locks/.wt-session-id, then $HOME/.chump/session_id).
# --since defaults to "cursor" so the recipient only sees new messages.
#
# Emits kind=inbox_advance event to ambient.jsonl after a successful cursor
# update, with {ts, kind, session, messages_read, new_offset}.
#
# INFRA-2006 (A2A inbox-routing bug fix): the `read` subcommand now unions
# messages from ALL inbox files owned by the current session — both the
# primary env-session-id inbox AND any lease-id inboxes (from claim-*.json
# files). This fixes the silent-loss bug where broadcast.sh --to <lease-id>
# wrote to a different file than the reader was checking. Deduplication is
# by message_id field (falls back to ts+session+kind triple).
#
# INFRA-1998 (Rust-first Phase 1): when CHUMP_MESSAGING_RUST=1, the
# `read` subcommand (default-path, no exotic flags) exec's the chump-inbox
# binary if it's on $PATH. All other subcommands + flag combinations
# (--json, --filter, --since iso-ts, count, tail) stay on the bash body
# below in Phase 1.

# ── INFRA-1998: selective Rust pass-through ──────────────────────────────────
if [[ "${CHUMP_MESSAGING_RUST:-0}" == "1" ]] && command -v chump-inbox >/dev/null 2>&1; then
    _SUB="${1:-}"
    if [[ "$_SUB" == "read" ]]; then
        # Scan remaining args for "exotic" flags Phase 1 Rust doesn't handle.
        # If any present, fall through to bash. Otherwise exec the binary.
        _ROUTE_RUST=1
        for _arg in "$@"; do
            case "$_arg" in
                --json|--filter)
                    _ROUTE_RUST=0
                    break
                    ;;
            esac
        done
        if [[ "$_ROUTE_RUST" -eq 1 ]]; then
            exec chump-inbox "$@"
        fi
    fi
fi

set -euo pipefail

# INFRA-2006: honour LOCK_DIR env override (used by tests and synthetic
# workspaces). Only fall back to git-derived path when not set.
if [[ -z "${LOCK_DIR:-}" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    _GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
    LOCK_DIR="$MAIN_REPO/.chump-locks"
fi
INBOX_DIR="$LOCK_DIR/inbox"
AMBIENT="$LOCK_DIR/ambient.jsonl"

# INFRA-2006: source inbox-routing helpers for multi-inbox union reads.
# Provide LOCK_DIR so the lib doesn't need to re-resolve it.
_IR_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/inbox-routing.sh"
if [[ -f "$_IR_LIB" ]]; then
    # shellcheck source=lib/inbox-routing.sh
    # shellcheck disable=SC1091
    source "$_IR_LIB"
    _HAS_ROUTING_LIB=1
else
    _HAS_ROUTING_LIB=0
fi

resolve_session() {
    local sid="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    if [[ -z "$sid" && -f "$LOCK_DIR/.wt-session-id" ]]; then
        sid="$(cat "$LOCK_DIR/.wt-session-id" 2>/dev/null || true)"
    fi
    if [[ -z "$sid" && -f "$HOME/.chump/session_id" ]]; then
        sid="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
    fi
    printf '%s' "$sid"
}

# INFRA-2006: return all inbox files this session should read (union of
# primary env-session inbox + all lease-id aliases). Falls back to just
# the primary inbox if the routing lib is unavailable.
collect_inbox_files() {
    if [[ "$_HAS_ROUTING_LIB" -eq 1 ]]; then
        resolve_inbox_targets
    else
        local primary; primary="$(resolve_session)"
        [[ -n "$primary" ]] && printf '%s\n' "$INBOX_DIR/$primary.jsonl"
    fi
}

# Emit kind=a2a_inbox_alias_resolved when we find messages in an alias file.
emit_alias_resolved() {
    local alias_file="$1" msg_count="$2"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local alias_name; alias_name="$(basename "$alias_file" .jsonl)"
    printf '{"ts":"%s","kind":"a2a_inbox_alias_resolved","session":"%s","alias_session":"%s","message_count":%d}\n' \
        "$ts" "$SESSION" "$alias_name" "$msg_count" >> "$AMBIENT" 2>/dev/null || true
}

# Emit kind=a2a_inbox_message_orphan for inboxes with no live session owner.
emit_orphan() {
    local orphan_file="$1" msg_count="$2"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"a2a_inbox_message_orphan","inbox_file":"%s","message_count":%d}\n' \
        "$ts" "$orphan_file" "$msg_count" >> "$AMBIENT" 2>/dev/null || true
}

SUB="${1:-help}"
shift || true

SESSION=""
SINCE="cursor"
FILTERS=()
WANT_JSON=0
NO_ADVANCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --session) SESSION="$2"; shift 2 ;;
        --since)   SINCE="$2"; shift 2 ;;
        --filter)  FILTERS+=("$2"); shift 2 ;;
        --json)    WANT_JSON=1; shift ;;
        --no-advance) NO_ADVANCE=1; shift ;;
        -h|--help)
            sed -n '2,21p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$SESSION" ]] || SESSION="$(resolve_session)"
[[ -n "$SESSION" ]] || { echo "no session id; set CHUMP_SESSION_ID or pass --session" >&2; exit 2; }

INBOX_FILE="$INBOX_DIR/$SESSION.jsonl"
CURSOR_FILE="$INBOX_DIR/$SESSION.cursor"

emit_advance() {
    local count="$1" new_offset="$2"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$LOCK_DIR"
    printf '{"ts":"%s","kind":"inbox_advance","session":"%s","messages_read":%d,"new_offset":%d}\n' \
        "$ts" "$SESSION" "$count" "$new_offset" >> "$AMBIENT" 2>/dev/null || true
}

case "$SUB" in
    count)
        if [[ -f "$INBOX_FILE" ]]; then
            wc -l < "$INBOX_FILE" | tr -d ' '
        else
            echo 0
        fi
        ;;
    tail)
        [[ -f "$INBOX_FILE" ]] || exit 0
        tail -f "$INBOX_FILE"
        ;;
    read)
        # INFRA-2006: collect ALL inbox files this session owns (primary +
        # lease-id aliases), union their contents, deduplicate by message_id.
        # bash 3.2-compatible: read loop instead of mapfile.
        mkdir -p "$INBOX_DIR"
        INBOX_FILES=()
        while IFS= read -r _line; do
            [[ -n "$_line" ]] && INBOX_FILES+=("$_line")
        done < <(collect_inbox_files)

        # Check whether any inbox file exists at all.
        _any_inbox=0
        for _f in "${INBOX_FILES[@]}"; do
            [[ -f "$_f" ]] && { _any_inbox=1; break; }
        done
        if [[ "$_any_inbox" -eq 0 ]]; then
            [[ "$WANT_JSON" -eq 1 ]] && echo "[]" || true
            exit 0
        fi

        # Build a merged slice tmp file from all inbox files.
        # For each file we apply the cursor independently (per-file cursor).
        # The primary file's cursor is the canonical one for --no-advance logic.
        merged_slice="$(mktemp "$INBOX_DIR/.read-slice.XXXXXX")"
        total_primary_size=0

        for _inbox_file in "${INBOX_FILES[@]}"; do
            [[ -f "$_inbox_file" ]] || continue
            _cursor_file="${_inbox_file%.jsonl}.cursor"
            # Substitute primary cursor path for the primary inbox.
            [[ "$_inbox_file" == "$INBOX_FILE" ]] && _cursor_file="$CURSOR_FILE"

            _local_offset=0
            case "$SINCE" in
                all) _local_offset=0 ;;
                cursor)
                    if [[ -f "$_cursor_file" ]]; then
                        _local_offset="$(cat "$_cursor_file" 2>/dev/null | tr -d '[:space:]')"
                        [[ "$_local_offset" =~ ^[0-9]+$ ]] || _local_offset=0
                    fi
                    ;;
                *) _local_offset=0 ;;
            esac
            _fsize="$(wc -c < "$_inbox_file" | tr -d ' ')"
            [[ "$_local_offset" -gt "$_fsize" ]] && _local_offset=0

            # Track primary file size for cursor advancement.
            if [[ "$_inbox_file" == "$INBOX_FILE" ]]; then
                total_primary_size="$_fsize"
            fi

            # Append new bytes from this file into the merged slice.
            if [[ "$_fsize" -gt "$_local_offset" ]]; then
                tail -c +"$((_local_offset + 1))" "$_inbox_file" >> "$merged_slice"

                # Emit alias-resolved event when messages come from a non-primary inbox.
                if [[ "$_inbox_file" != "$INBOX_FILE" ]]; then
                    _alias_lines="$(tail -c +"$((_local_offset + 1))" "$_inbox_file" | grep -c '' 2>/dev/null || true)"
                    if [[ "$_alias_lines" -gt 0 ]]; then
                        emit_alias_resolved "$_inbox_file" "$_alias_lines"
                    fi
                fi

                # Advance per-alias cursor atomically (non-primary files only).
                if [[ "$NO_ADVANCE" -ne 1 && "$_inbox_file" != "$INBOX_FILE" ]]; then
                    _ctmp="${_cursor_file}.tmp.$$"
                    printf '%s' "$_fsize" > "$_ctmp"
                    mv "$_ctmp" "$_cursor_file"
                fi
            fi
        done

        if [[ ! -s "$merged_slice" ]]; then
            rm -f "$merged_slice"
            [[ "$WANT_JSON" -eq 1 ]] && echo "[]" || true
            exit 0
        fi

        # Filter + deduplicate via python.
        # argv: <merged-slice> <since> <want-json> <filter1> ...
        filtered="$(python3 - "$merged_slice" "$SINCE" "$WANT_JSON" ${FILTERS[@]+"${FILTERS[@]}"} <<'PY'
import json, sys
slice_path = sys.argv[1]
since = sys.argv[2]
want_json = sys.argv[3] == "1"
filters = sys.argv[4:]

predicates = []
for raw in filters:
    if not raw:
        continue
    for piece in raw.split(","):
        if "=" in piece:
            k, v = piece.split("=", 1)
            predicates.append((k.strip(), v.strip()))

since_dt = None
if since not in ("cursor", "all"):
    try:
        from datetime import datetime
        since_dt = datetime.fromisoformat(since.replace("Z", "+00:00"))
    except Exception:
        since_dt = None

def dedup_key(evt):
    """Stable deduplication key: message_id field, or ts+session+kind triple."""
    mid = evt.get("message_id")
    if mid:
        return ("mid", mid)
    return ("tsk", evt.get("ts",""), evt.get("session",""), evt.get("kind", evt.get("event","")))

seen_keys = set()
matched = []
with open(slice_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            evt = json.loads(line)
        except Exception:
            continue
        # Deduplicate.
        dk = dedup_key(evt)
        if dk in seen_keys:
            continue
        seen_keys.add(dk)
        # Apply predicates.
        if predicates:
            ok = True
            for k, v in predicates:
                if k in ("kind", "event"):
                    if evt.get("kind") != v and evt.get("event") != v:
                        ok = False; break
                elif k == "from":
                    if evt.get("session") != v: ok = False; break
                else:
                    if str(evt.get(k, "")) != v: ok = False; break
            if not ok:
                continue
        # Apply since timestamp filter.
        if since_dt is not None:
            try:
                from datetime import datetime
                evt_dt = datetime.fromisoformat(evt.get("ts", "").replace("Z", "+00:00"))
                if evt_dt < since_dt:
                    continue
            except Exception:
                pass
        matched.append(evt)

if want_json:
    print(json.dumps(matched, indent=2))
else:
    for m in matched:
        print(json.dumps(m))
PY
        )"
        rm -f "$merged_slice"
        if [[ -n "$filtered" ]]; then
            printf '%s\n' "$filtered"
        elif [[ "$WANT_JSON" -eq 1 ]]; then
            echo "[]"
        fi

        if [[ "$NO_ADVANCE" -ne 1 ]]; then
            # Advance the primary inbox cursor atomically.
            tmp="$CURSOR_FILE.tmp.$$"
            printf '%s' "$total_primary_size" > "$tmp"
            mv "$tmp" "$CURSOR_FILE"
            # Count emitted lines for the advance event.
            slice_lines="$(printf '%s' "$filtered" | grep -c '' || true)"
            emit_advance "$slice_lines" "$total_primary_size"
        fi
        ;;
    help|"")
        sed -n '2,21p' "$0"
        ;;
    *)
        echo "unknown subcommand: $SUB" >&2
        echo "valid: read | count | tail | help" >&2
        exit 2
        ;;
esac
