#!/usr/bin/env bash
# scripts/coord/rpc/_rpc_lib.sh — INFRA-1828 v0 transport for INFRA-1759 stubs
#
# Shared helper for the 5 ask-* RPC wrappers. Implements the request/poll
# loop over canonical INFRA-1115 broadcast.sh + chump-inbox.sh transport.
#
# Public entry points (callers source this file then invoke):
#
#   _rpc_send  <target_session> <method> <args_json>
#     → emits a WARN event to <target>'s inbox carrying {request_id, method, args}
#     → returns the request_id on stdout
#
#   _rpc_await <request_id> [timeout_seconds]
#     → polls our own inbox for a reply with corr_id=<request_id>
#     → on success: prints the reply's note field (the JSON payload)
#     → on timeout: emits kind=a2a_rpc_timeout and returns rc=124
#
#   _rpc_call  <target_session> <method> <args_json> [timeout_seconds]
#     → convenience: _rpc_send | _rpc_await as a single shot
#
# Wire-format:
#   request:  WARN to=<target> reason='{"rpc":"<method>","request_id":"<id>","args":<args_json>}'
#   reply:    WARN to=<requester> corr_id=<id> reason='<json_response>'
#
# When INFRA-1119 lands in Rust, the on-wire format is preserved so this
# v0 keeps working alongside the typed implementation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
DEFAULT_RPC_TIMEOUT_S="${CHUMP_RPC_TIMEOUT_S:-10}"

_rpc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Generate a request_id: ts-randHex (no uuid CLI dep).
_rpc_new_request_id() {
    local rnd
    rnd="$(printf '%04x' $(( RANDOM * RANDOM % 65536 )))"
    printf 'rpc-%s-%s' "$(date -u +%s)" "$rnd"
}

# Resolve our session ID for self-inbox polling.
_rpc_self_session() {
    echo "${CHUMP_SESSION_ID:-${SESSION_ID:-${CLAUDE_SESSION_ID:-$(hostname)-$$}}}"
}

_rpc_send() {
    local target="$1" method="$2" args_json="$3"
    local req_id payload
    req_id="$(_rpc_new_request_id)"
    # Compact-mode envelope so grep matches survive python emits.
    payload="$(python3 -c "
import json,sys
args_raw = sys.argv[1]
try:
    args = json.loads(args_raw) if args_raw else {}
except Exception:
    args = {'raw': args_raw}
print(json.dumps({'rpc': sys.argv[2], 'request_id': sys.argv[3], 'args': args},
                  separators=(',', ':')))
" "$args_json" "$method" "$req_id")"

    bash "$REPO_ROOT/scripts/coord/broadcast.sh" --to "$target" WARN \
        --reason "$payload" >/dev/null 2>&1 || {
        printf '{"ts":"%s","kind":"a2a_rpc_send_failed","method":"%s","target":"%s","request_id":"%s"}\n' \
            "$(_rpc_now)" "$method" "$target" "$req_id" >> "$AMBIENT_LOG" 2>/dev/null || true
        return 1
    }

    printf '{"ts":"%s","kind":"a2a_rpc_sent","method":"%s","target":"%s","request_id":"%s"}\n' \
        "$(_rpc_now)" "$method" "$target" "$req_id" >> "$AMBIENT_LOG" 2>/dev/null || true

    echo "$req_id"
}

# Block until a reply with corr_id=<req_id> shows up in our inbox OR timeout.
# Reads the inbox raw (not the cursor-advancing read) so other consumers
# aren't disturbed.
_rpc_await() {
    local req_id="$1"
    local timeout_s="${2:-$DEFAULT_RPC_TIMEOUT_S}"
    local self_session inbox_file deadline
    self_session="$(_rpc_self_session)"
    inbox_file="$LOCK_DIR/inbox/${self_session//[\/:]/_}.jsonl"
    deadline=$(( $(date -u +%s) + timeout_s ))

    while (( $(date -u +%s) < deadline )); do
        if [[ -r "$inbox_file" ]]; then
            local reply
            reply="$(python3 - "$inbox_file" "$req_id" <<'PYEOF'
import json, sys
inbox = sys.argv[1]
needle = sys.argv[2]
try:
    with open(inbox) as f:
        for line in f:
            line = line.strip()
            if not line or needle not in line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            # Check both top-level corr_id AND embedded in reason payload
            if e.get("corr_id") == needle:
                print(e.get("reason", "") or e.get("note", ""))
                sys.exit(0)
            r = e.get("reason", "")
            if r and needle in r:
                try:
                    parsed = json.loads(r)
                    if isinstance(parsed, dict) and parsed.get("corr_id") == needle:
                        print(r)
                        sys.exit(0)
                except Exception:
                    pass
except FileNotFoundError:
    pass
sys.exit(2)
PYEOF
            )" && {
                echo "$reply"
                return 0
            }
        fi
        sleep 0.5
    done

    # Timeout: audit + non-zero rc.
    printf '{"ts":"%s","kind":"a2a_rpc_timeout","request_id":"%s","timeout_s":%d}\n' \
        "$(_rpc_now)" "$req_id" "$timeout_s" >> "$AMBIENT_LOG" 2>/dev/null || true
    return 124
}

_rpc_call() {
    local target="$1" method="$2" args_json="$3"
    local timeout_s="${4:-$DEFAULT_RPC_TIMEOUT_S}"
    local req_id
    req_id="$(_rpc_send "$target" "$method" "$args_json")" || return 1
    _rpc_await "$req_id" "$timeout_s"
}

export _CHUMP_RPC_LIB_LOADED=1
