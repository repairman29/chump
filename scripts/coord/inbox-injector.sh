#!/usr/bin/env bash
# scripts/coord/inbox-injector.sh — INFRA-2014 (the "magic" — live A2A injection)
#
# Watches .chump-locks/inbox/*.jsonl for NEW high-urgency messages and
# slips them in front of running fleet-worker tmux panes via send-keys.
#
# Converts A2A from "dead-letter mailbox checked at SessionStart" into
# "live signal that interrupts the agent within seconds." Operator's
# constraint: "magical. agents understand sometimes we MUST get a
# message in front of them. start with full stop/restart on CRIT;
# eventually fast AF + non-destructive."
#
# Phase 1 (this MVP):
#   - Polls inbox files every 10 sec
#   - Classifies each new message by urgency (see _classify_urgency)
#   - For CRIT/EMERGENCY: tmux send-keys an interrupt to the recipient pane
#   - Non-destructive guard: only injects when pane is at prompt (capture-pane
#     check) — never mid-tool-execution
#
# Phase 2 (INFRA-2015): formal --urgency CSV in broadcast.sh
# Phase 3 (INFRA-2016): PreToolUse hook for fully non-destructive in-Claude path
#
# Bypass: CHUMP_INBOX_INJECTOR_PAUSE=1
#
# Config:
#   CHUMP_INBOX_INJECTOR_INTERVAL  poll interval seconds (default 10)
#   CHUMP_INBOX_INJECTOR_PAUSE     if 1, short-circuit
#   CHUMP_INBOX_INJECTOR_TEST_TMUX  test injection: redirect tmux to a log

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
INBOX_DIR="$REPO_ROOT/.chump-locks/inbox"
STATE="$REPO_ROOT/.chump-locks/inbox-injector-state.json"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
INTERVAL="${CHUMP_INBOX_INJECTOR_INTERVAL:-10}"
TMUX_BIN="${CHUMP_INBOX_INJECTOR_TEST_TMUX:-tmux}"

mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true

if [[ "${CHUMP_INBOX_INJECTOR_PAUSE:-0}" == "1" ]]; then
    printf '{"ts":"%s","kind":"inbox_injector_paused","source":"inbox_injector"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$AMBIENT" 2>/dev/null || true
    exit 0
fi

[[ -d "$INBOX_DIR" ]] || exit 0

# ── State helpers ────────────────────────────────────────────────────────────
# State tracks per-recipient last-injected-line-number so we don't re-inject.
_load_state() {
    if [[ -f "$STATE" ]]; then cat "$STATE"; else echo '{}'; fi
}
_save_state() {
    echo "$1" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    printf '{"ts":"%s","kind":"%s","source":"inbox_injector"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$extra" \
        >> "$AMBIENT" 2>/dev/null || true
}

# ── Urgency classifier ──────────────────────────────────────────────────────
# Heuristic until INFRA-2015 ships formal --urgency flag in broadcast.sh.
# Returns: EMERGENCY | CRIT | WARN | INFO
_classify_urgency() {
    local line="$1"
    # 1. Explicit urgency field if present (when INFRA-2015 lands)
    local explicit
    explicit="$(echo "$line" | python3 -c '
import json, sys
try:
    o = json.loads(sys.stdin.read())
    if isinstance(o, dict):
        u = (o.get("urgency") or "").upper()
        if u in ("INFO","WARN","CRIT","EMERGENCY"):
            print(u)
except: pass
' 2>/dev/null)"
    if [[ -n "$explicit" ]]; then echo "$explicit"; return; fi

    # 2. Event-type heuristic
    local ev
    ev="$(echo "$line" | python3 -c '
import json, sys
try:
    o = json.loads(sys.stdin.read())
    if isinstance(o, dict): print(o.get("event","INFO"))
except: pass
' 2>/dev/null)"
    case "$ev" in
        ALERT) echo "CRIT"; return ;;
        STUCK) echo "CRIT"; return ;;
        WARN)  echo "WARN"; return ;;
    esac

    # 3. Body keyword heuristic
    local body
    body="$(echo "$line" | python3 -c '
import json, sys
try:
    o = json.loads(sys.stdin.read())
    if isinstance(o, dict): print((o.get("gap") or o.get("reason") or "")[:500])
except: pass
' 2>/dev/null)"
    if echo "$body" | grep -qiE "EMERGENCY|DATA[ _-]LOSS|stale.base"; then
        echo "EMERGENCY"; return
    fi
    if echo "$body" | grep -qiE "TRUNK[ _-]RED|stuck.AF|critical|CRIT|stuck for"; then
        echo "CRIT"; return
    fi
    echo "INFO"
}

# ── Find tmux pane for a session ────────────────────────────────────────────
# Returns the tmux target (session:window.pane) if found, empty if not.
# Match strategy: pane title or window name contains the session_id.
_find_pane() {
    local session="$1"
    "$TMUX_BIN" list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{window_name}' 2>/dev/null \
        | grep -F "$session" | head -1 | awk '{print $1}'
}

# ── Non-destructive guard: only inject when pane appears idle ───────────────
# Heuristic: capture last 3 lines of pane; if last line ends with ">" or "$"
# or a typical Claude prompt token, agent is waiting for input.
_pane_is_idle() {
    local pane="$1"
    local tail
    tail="$("$TMUX_BIN" capture-pane -p -t "$pane" -S -3 2>/dev/null)"
    # Crude: if the last non-empty line ends with > or $ or includes "Human:" prompt
    echo "$tail" | grep -qE '(^|[[:space:]])(>|\$|Human:)[[:space:]]*$'
}

# ── Inject interrupt into a pane ────────────────────────────────────────────
_inject() {
    local pane="$1"
    local urgency="$2"
    local sender="$3"
    local body_preview="$4"
    [[ -z "$pane" ]] && return 1

    local msg
    case "$urgency" in
        EMERGENCY)
            msg="** INBOX EMERGENCY from $sender ** STOP — run: bash scripts/coord/chump-inbox.sh read"
            # EMERGENCY: also Ctrl-C to break current input
            "$TMUX_BIN" send-keys -t "$pane" C-c 2>/dev/null
            sleep 0.3
            ;;
        CRIT)
            msg="** INBOX CRIT from $sender ** $body_preview — run: bash scripts/coord/chump-inbox.sh read"
            ;;
        *)
            return 0  # WARN/INFO don't inject
            ;;
    esac

    "$TMUX_BIN" send-keys -t "$pane" "$msg" Enter 2>/dev/null
    _emit "inbox_injection_executed" \
        "\"recipient_pane\":\"$pane\"" \
        "\"urgency\":\"$urgency\"" \
        "\"sender\":\"$sender\""
    echo "[inject] urgency=$urgency pane=$pane sender=$sender" >&2
}

# ── Main poll loop (one tick — launchd handles cadence) ────────────────────
_process_inbox() {
    local inbox_file="$1"
    local recipient
    recipient="$(basename "$inbox_file" .jsonl)"
    # Skip cursor files
    [[ "$recipient" == *.cursor ]] && return

    local state; state="$(_load_state)"
    local last_n
    last_n="$(echo "$state" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin)
    print(s.get('$recipient', 0))
except: print(0)
" 2>/dev/null)"
    last_n="${last_n:-0}"

    local total
    total="$(wc -l < "$inbox_file" | xargs)"
    [[ "$total" -le "$last_n" ]] && return  # no new messages

    # Find target pane for this recipient
    local pane
    pane="$(_find_pane "$recipient")"
    if [[ -z "$pane" ]]; then
        # No tmux pane = recipient not running interactively; skip silently
        # Update state so we don't re-check until new messages arrive
        local new_state
        new_state="$(echo "$state" | python3 -c "
import json, sys
try: s = json.load(sys.stdin)
except: s = {}
s['$recipient'] = $total
print(json.dumps(s))
")"
        _save_state "$new_state"
        return
    fi

    # Process new messages
    local injected=0
    tail -n +"$((last_n + 1))" "$inbox_file" 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local urgency; urgency="$(_classify_urgency "$line")"
        case "$urgency" in
            CRIT|EMERGENCY)
                # Idle-check before injection
                if ! _pane_is_idle "$pane"; then
                    echo "[skip] pane $pane not idle, deferring" >&2
                    continue
                fi
                local sender body_preview
                sender="$(echo "$line" | python3 -c 'import json,sys; o=json.loads(sys.stdin.read()); print(o.get("session","unknown") if isinstance(o,dict) else "unknown")' 2>/dev/null)"
                body_preview="$(echo "$line" | python3 -c 'import json,sys; o=json.loads(sys.stdin.read()); b=(o.get("gap","") or o.get("reason","") or "")[:80].replace("\n"," ") if isinstance(o,dict) else ""; print(b)' 2>/dev/null)"
                _inject "$pane" "$urgency" "$sender" "$body_preview"
                injected=$((injected+1))
                ;;
        esac
    done

    # Advance state past all processed messages
    local new_state
    new_state="$(echo "$state" | python3 -c "
import json, sys
try: s = json.load(sys.stdin)
except: s = {}
s['$recipient'] = $total
print(json.dumps(s))
")"
    _save_state "$new_state"
}

# ── Top-level: scan all inbox files ─────────────────────────────────────────
for inbox in "$INBOX_DIR"/*.jsonl; do
    [[ -f "$inbox" ]] || continue
    _process_inbox "$inbox"
done

exit 0
