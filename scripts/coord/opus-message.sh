#!/usr/bin/env bash
# scripts/coord/opus-message.sh — INFRA-1796
#
# v0 addressed-async DM channel between Opus sessions. Bridge utility until
# INFRA-1759 (A2A Layer 2b RPC) lands the full pub/sub + request/response
# stack. ~50 LOC; gives operators an addressed messaging primitive TODAY.
#
# Inbox layout:
#   .chump-locks/opus-inbox/<recipient>.jsonl
#     where <recipient> is one of:
#       gap:<GAP-ID>   — routed at send-time to whoever leases that gap
#       session:<id>   — direct to a specific session
#       all-opus       — broadcast inbox every Opus reads
#
# Each line is a single JSON object: {id, ts, from, to, body, ref, read_at}
#
# Usage:
#   opus-message.sh send --to <recipient> --from <my-id> --body "<text>" [--ref <pr-or-gap>]
#   opus-message.sh list [--unread] [--for <recipient>]
#   opus-message.sh mark-read <message-id> [--for <recipient>]

set -euo pipefail

# ── Locate repo root ────────────────────────────────────────────────────────
if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
INBOX_DIR="${CHUMP_OPUS_INBOX_DIR:-$REPO_ROOT/.chump-locks/opus-inbox}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LEASE_DIR="${CHUMP_LEASE_DIR:-$REPO_ROOT/.chump-locks}"

mkdir -p "$INBOX_DIR" 2>/dev/null || true

# ── Helpers ─────────────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_msg_id() {
    # 12-char id derived from ts + random; collision-resistant enough for v0
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr -d '-' | cut -c1-12
    else
        printf '%s%05d' "$(date +%s)" "$RANDOM"
    fi
}

_emit_ambient() {
    local payload="$1"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '%s\n' "$payload" >> "$AMBIENT" 2>/dev/null || true
}

# Given "gap:INFRA-NNN", look up the lease holder's session-id from
# .chump-locks/*.json. Falls back to gap:<ID> as a stable inbox slot (anyone
# claiming that gap later will read it on next session-start).
_resolve_recipient() {
    local to="$1"
    case "$to" in
        gap:*)
            local gap="${to#gap:}"
            local session
            session="$(python3 - "$LEASE_DIR" "$gap" 2>/dev/null <<'PYEOF'
import json, os, sys, glob
lease_dir, gap = sys.argv[1], sys.argv[2]
for path in glob.glob(os.path.join(lease_dir, "*.json")):
    try:
        with open(path) as f: d = json.load(f)
    except Exception:
        continue
    purpose = (d.get("purpose") or "")
    if purpose == f"gap:{gap}" or d.get("gap_id") == gap:
        print(d.get("session_id") or os.path.basename(path).removesuffix(".json"))
        sys.exit(0)
PYEOF
)" || true
            if [[ -n "$session" ]]; then
                printf 'session:%s\n' "$session"
            else
                # No active lease — use the gap-slot as durable mailbox.
                # Next session to claim this gap reads it at session-start.
                printf 'gap:%s\n' "$gap"
            fi
            ;;
        session:*|all-opus)
            printf '%s\n' "$to"
            ;;
        *)
            echo "opus-message: unknown recipient form '$to' (want gap:<ID> | session:<id> | all-opus)" >&2
            return 2
            ;;
    esac
}

_inbox_path() {
    # Convert recipient to a filesystem-safe filename.
    local recipient="$1"
    local safe
    safe="$(printf '%s' "$recipient" | tr ':/' '__')"
    printf '%s/%s.jsonl\n' "$INBOX_DIR" "$safe"
}

# ── send ────────────────────────────────────────────────────────────────────
cmd_send() {
    local to="" from="" body="" ref=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to)   to="$2"; shift 2 ;;
            --from) from="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --ref)  ref="$2"; shift 2 ;;
            *) echo "opus-message send: unknown flag '$1'" >&2; exit 2 ;;
        esac
    done
    if [[ -z "$to" || -z "$body" ]]; then
        echo "opus-message send: --to and --body required" >&2
        exit 2
    fi
    [[ -z "$from" ]] && from="${CHUMP_SESSION_ID:-$(hostname)-$$}"

    local resolved
    resolved="$(_resolve_recipient "$to")"
    local inbox
    inbox="$(_inbox_path "$resolved")"
    mkdir -p "$(dirname "$inbox")" 2>/dev/null || true

    local id ts
    id="$(_msg_id)"
    ts="$(_ts)"

    # Build JSON via python for proper escaping (body may contain quotes).
    python3 - "$id" "$ts" "$from" "$to" "$body" "$ref" "$inbox" <<'PYEOF'
import json, sys
mid, ts, src, dst, body, ref, inbox = sys.argv[1:8]
record = {"id": mid, "ts": ts, "from": src, "to": dst, "body": body, "ref": ref, "read_at": None}
with open(inbox, "a") as f:
    f.write(json.dumps(record) + "\n")
PYEOF

    local ambient_line
    ambient_line="$(python3 - "$ts" "$to" "$from" "$ref" "$id" <<'PYEOF'
import json, sys
ts, dst, src, ref, mid = sys.argv[1:6]
print(json.dumps({"ts": ts, "kind": "opus_message_sent", "to": dst, "from": src, "ref": ref, "msg_id": mid}))
PYEOF
)"
    _emit_ambient "$ambient_line"

    echo "$id"
}

# ── list ────────────────────────────────────────────────────────────────────
cmd_list() {
    local unread_only=0 for_recipient=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --unread)  unread_only=1; shift ;;
            --for)     for_recipient="$2"; shift 2 ;;
            *) echo "opus-message list: unknown flag '$1'" >&2; exit 2 ;;
        esac
    done
    [[ -z "$for_recipient" ]] && for_recipient="${CHUMP_SESSION_ID:-$(hostname)-$$}"

    # Resolve session:<id> automatically if bare id given.
    case "$for_recipient" in
        session:*|gap:*|all-opus) ;;
        *) for_recipient="session:$for_recipient" ;;
    esac

    local inbox
    inbox="$(_inbox_path "$for_recipient")"
    if [[ ! -f "$inbox" ]]; then
        echo "(no messages for $for_recipient)"
        return 0
    fi

    python3 - "$inbox" "$unread_only" <<'PYEOF'
import json, sys
inbox, unread_only = sys.argv[1], int(sys.argv[2])
with open(inbox) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            m = json.loads(line)
        except Exception:
            continue
        if unread_only and m.get("read_at"):
            continue
        read = "○" if not m.get("read_at") else "✓"
        print(f"{read} {m['id']}  {m['ts']}  from={m['from']}  to={m['to']}  ref={m.get('ref','')}")
        print(f"   {m['body']}")
PYEOF
}

# ── mark-read ───────────────────────────────────────────────────────────────
cmd_mark_read() {
    local msg_id="" for_recipient=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --for) for_recipient="$2"; shift 2 ;;
            -*) echo "opus-message mark-read: unknown flag '$1'" >&2; exit 2 ;;
            *) msg_id="$1"; shift ;;
        esac
    done
    [[ -z "$msg_id" ]] && { echo "opus-message mark-read: <message-id> required" >&2; exit 2; }
    [[ -z "$for_recipient" ]] && for_recipient="${CHUMP_SESSION_ID:-$(hostname)-$$}"
    case "$for_recipient" in
        session:*|gap:*|all-opus) ;;
        *) for_recipient="session:$for_recipient" ;;
    esac

    local inbox
    inbox="$(_inbox_path "$for_recipient")"
    if [[ ! -f "$inbox" ]]; then
        echo "opus-message: no inbox at $inbox" >&2
        exit 1
    fi

    local now
    now="$(_ts)"
    local tmp
    tmp="$(mktemp)"
    trap "rm -f '$tmp'" EXIT
    python3 - "$inbox" "$msg_id" "$now" > "$tmp" <<'PYEOF'
import json, sys
inbox, target_id, now = sys.argv[1], sys.argv[2], sys.argv[3]
hit = False
with open(inbox) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            m = json.loads(line)
        except Exception:
            print(line); continue
        if m.get("id") == target_id and not m.get("read_at"):
            m["read_at"] = now
            hit = True
        print(json.dumps(m))
sys.exit(0 if hit else 1)
PYEOF
    if [[ $? -eq 0 ]]; then
        mv "$tmp" "$inbox"
        echo "marked $msg_id read at $now"
    else
        echo "opus-message: message $msg_id not found (or already read)" >&2
        rm -f "$tmp"
        exit 1
    fi
}

# ── dispatch ────────────────────────────────────────────────────────────────
case "${1:-}" in
    send)      shift; cmd_send "$@" ;;
    list)      shift; cmd_list "$@" ;;
    mark-read) shift; cmd_mark_read "$@" ;;
    -h|--help|"")
        sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) echo "opus-message: unknown command '$1' (want send|list|mark-read)" >&2; exit 2 ;;
esac
