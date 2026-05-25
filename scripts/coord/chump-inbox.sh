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

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
INBOX_DIR="$LOCK_DIR/inbox"
AMBIENT="$LOCK_DIR/ambient.jsonl"

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
        if [[ ! -f "$INBOX_FILE" ]]; then
            [[ "$WANT_JSON" -eq 1 ]] && echo "[]" || true
            exit 0
        fi
        # Resolve --since to a byte offset.
        local_offset=0
        case "$SINCE" in
            all) local_offset=0 ;;
            cursor)
                if [[ -f "$CURSOR_FILE" ]]; then
                    local_offset="$(cat "$CURSOR_FILE" 2>/dev/null | tr -d '[:space:]')"
                    [[ "$local_offset" =~ ^[0-9]+$ ]] || local_offset=0
                fi
                ;;
            *)
                # Treat as ISO timestamp; python filters lines by ts.
                local_offset=0
                ;;
        esac
        file_size="$(wc -c < "$INBOX_FILE" | tr -d ' ')"
        if [[ "$local_offset" -gt "$file_size" ]]; then
            # File was truncated/archived; reset to start.
            local_offset=0
        fi
        # Write the tail slice to a temp file so python can read it without
        # colliding with the python-script-on-stdin convention.
        slice_file="$(mktemp "$INBOX_DIR/.read-slice.XXXXXX")"
        tail -c +"$((local_offset + 1))" "$INBOX_FILE" > "$slice_file"
        if [[ ! -s "$slice_file" ]]; then
            rm -f "$slice_file"
            [[ "$WANT_JSON" -eq 1 ]] && echo "[]" || true
            exit 0
        fi

        # Filter via python: argv order is <slice-file> <since> <want-json> <filter1> <filter2> ...
        # ${arr[@]+"${arr[@]}"} is the bash 3.2-safe "expand-or-nothing" idiom
        # for an array that may be empty under set -u.
        filtered="$(python3 - "$slice_file" "$SINCE" "$WANT_JSON" ${FILTERS[@]+"${FILTERS[@]}"} <<'PY'
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
        rm -f "$slice_file"
        if [[ -n "$filtered" ]]; then
            printf '%s\n' "$filtered"
        elif [[ "$WANT_JSON" -eq 1 ]]; then
            echo "[]"
        fi

        if [[ "$NO_ADVANCE" -ne 1 ]]; then
            # Atomic cursor update via rename.
            tmp="$CURSOR_FILE.tmp.$$"
            printf '%s' "$file_size" > "$tmp"
            mv "$tmp" "$CURSOR_FILE"
            # Count emitted lines (one per matched event, plus possibly a JSON wrapper line).
            slice_lines="$(printf '%s' "$filtered" | grep -c '' || true)"
            emit_advance "$slice_lines" "$file_size"
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
