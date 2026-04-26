#!/usr/bin/env bash
# heartbeat-watcher.sh — daemon that watches ambient.jsonl for silent_agent alerts
# and either restarts the agent or escalates to the ambient stream.
#
# Usage:
#   scripts/dev/heartbeat-watcher.sh start    # start daemon in background
#   scripts/dev/heartbeat-watcher.sh stop     # stop running daemon
#   scripts/dev/heartbeat-watcher.sh status   # show PID and daemon state
#
# Behaviour on silent_agent detection:
#   - Reads .chump-locks/<sid>.json for gap_id, working_dir, last_command
#   - If last_command contains "--resume": re-runs it after a 30s delay (avoids tight loops)
#   - Otherwise: appends an escalation entry to ambient.jsonl
#
# PID file: .chump-locks/.heartbeat-watcher.pid
#
# Environment:
#   CHUMP_AMBIENT_LOG   override ambient log path (default: <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_LOCK_DIR      override lock dir path (default: <repo>/.chump-locks)
#   RESTART_DELAY_SECS  seconds to wait before re-running a --resume command (default: 30)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
PID_FILE="$LOCK_DIR/.heartbeat-watcher.pid"
RESTART_DELAY_SECS="${RESTART_DELAY_SECS:-30}"
DAEMON_LOG="$LOCK_DIR/.heartbeat-watcher.log"

mkdir -p "$LOCK_DIR"

# ── Helper: emit an event to ambient.jsonl using ambient-emit.sh or inline ────
emit_event() {
    local kind="$1"
    shift
    local emit_script="$REPO_ROOT/scripts/dev/ambient-emit.sh"
    if [[ -x "$emit_script" ]]; then
        CHUMP_SESSION_ID="heartbeat-watcher" "$emit_script" "$kind" "$@" 2>/dev/null || true
    else
        # Inline fallback — write raw JSON if ambient-emit.sh is unavailable
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local extra=""
        for arg in "$@"; do
            local k="${arg%%=*}"
            local v="${arg#*=}"
            v_esc="$(python3 -c "import json,sys; print(json.dumps(sys.argv[1])[1:-1])" "$v" 2>/dev/null || printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            extra="${extra},\"${k}\":\"${v_esc}\""
        done
        local line="{\"ts\":\"${ts}\",\"session\":\"heartbeat-watcher\",\"worktree\":\"$(basename "$REPO_ROOT")\",\"event\":\"${kind}\"${extra}}"
        printf '%s\n' "$line" >> "$AMBIENT_LOG"
    fi
}

# ── Helper: write daemon log ────────────────────────────────────────────────
log() {
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] heartbeat-watcher: %s\n' "$ts" "$*" | tee -a "$DAEMON_LOG" >&2
}

# ── Handle a single silent_agent event ────────────────────────────────────────
handle_silent_agent() {
    local raw_event="$1"

    # Extract session ID from event JSON (support both "session" and "sid" keys)
    local sid
    sid="$(python3 -c "
import json, sys
try:
    ev = json.loads(sys.argv[1])
    # ambient-watch.sh emits 'session' field; also accept 'sid' for flexibility
    print(ev.get('session') or ev.get('sid') or '')
except Exception:
    print('')
" "$raw_event" 2>/dev/null || true)"

    if [[ -z "$sid" ]]; then
        log "silent_agent event with no session ID — skipping: $raw_event"
        return
    fi

    # Sanitise for use as a filename (same logic as gap-claim.sh)
    local safe_sid="${sid//[^a-zA-Z0-9_-]/_}"
    local lease_file="$LOCK_DIR/${safe_sid}.json"

    local gap_id="" working_dir="" last_command=""
    if [[ -f "$lease_file" ]]; then
        gap_id="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('gap_id', ''))
except Exception:
    print('')
" "$lease_file" 2>/dev/null || true)"

        working_dir="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('working_dir', ''))
except Exception:
    print('')
" "$lease_file" 2>/dev/null || true)"

        last_command="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('last_command', ''))
except Exception:
    print('')
" "$lease_file" 2>/dev/null || true)"
    else
        log "No lease file for session $sid — escalating immediately"
    fi

    log "Detected silent agent: sid=$sid gap=${gap_id:-unknown}"

    # Decision: if last_command contains --resume, restart; otherwise escalate
    if [[ -n "$last_command" ]] && printf '%s' "$last_command" | grep -q -- '--resume'; then
        log "last_command contains --resume — will restart in ${RESTART_DELAY_SECS}s: $last_command"
        sleep "$RESTART_DELAY_SECS"

        # Re-run the command, optionally in the declared working_dir
        if [[ -n "$working_dir" ]] && [[ -d "$working_dir" ]]; then
            log "Restarting in working_dir=$working_dir"
            (cd "$working_dir" && eval "$last_command") &
        else
            log "Restarting from repo root"
            (cd "$REPO_ROOT" && eval "$last_command") &
        fi

        emit_event "restart" \
            "agent_id=heartbeat-watcher" \
            "restarted_session=$sid" \
            "gap_id=${gap_id}" \
            "command=$last_command"
    else
        # No resumable command — escalate
        local msg="silent agent ${sid} on gap ${gap_id:-unknown} — restart not supported, manual intervention required"
        log "Escalating: $msg"
        emit_event "escalation" \
            "agent_id=heartbeat-watcher" \
            "message=$msg"
    fi
}

# ── Watch loop (runs in daemon background) ────────────────────────────────────
run_watcher() {
    log "Started (pid=$$, ambient_log=$AMBIENT_LOG)"
    emit_event "session_start" "gap=INFRA-HEARTBEAT-WATCHER" "role=heartbeat-watcher"

    # Track events already handled to avoid re-processing on log rotation
    local last_handled_ts=""

    # tail -f is the most reliable way to watch a growing JSONL file.
    # We use a Python helper to parse lines and detect silent_agent events,
    # printing matched lines to stdout for the shell handler.
    tail -f "$AMBIENT_LOG" 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Detect silent_agent events (two formats: JSON kind field, or ALERT kind=silent_agent)
        local is_silent=0
        if python3 -c "
import json, sys
try:
    ev = json.loads(sys.argv[1])
    # Emitted by ambient-watch.sh: event='ALERT', kind='silent_agent'
    # or event='silent_agent' directly
    if ev.get('event') == 'silent_agent':
        sys.exit(0)
    if ev.get('event') == 'ALERT' and ev.get('kind') == 'silent_agent':
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" "$line" 2>/dev/null; then
            is_silent=1
        # Also catch old-style plain-text ALERT lines: ALERT kind=silent_agent ...
        elif printf '%s' "$line" | grep -qE '"ALERT".*"silent_agent"|kind.*silent_agent'; then
            is_silent=1
        fi

        if [[ "$is_silent" -eq 1 ]]; then
            log "Received silent_agent event: $line"
            handle_silent_agent "$line"
        fi
    done
}

# ── start / stop / status commands ────────────────────────────────────────────
cmd="${1:-}"

case "$cmd" in
    start)
        # Prevent multiple instances via PID file
        if [[ -f "$PID_FILE" ]]; then
            existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
            if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
                echo "[heartbeat-watcher] Already running (pid=$existing_pid). Use 'stop' first." >&2
                exit 1
            else
                # Stale PID file — remove and continue
                rm -f "$PID_FILE"
            fi
        fi

        # Ensure ambient log exists so tail -f can open it
        touch "$AMBIENT_LOG"

        # Fork the watcher into the background
        run_watcher &
        WATCHER_PID=$!
        printf '%d\n' "$WATCHER_PID" > "$PID_FILE"
        echo "[heartbeat-watcher] Started (pid=$WATCHER_PID, log=$DAEMON_LOG)"
        ;;

    stop)
        if [[ ! -f "$PID_FILE" ]]; then
            echo "[heartbeat-watcher] Not running (no PID file at $PID_FILE)."
            exit 0
        fi
        existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -z "$existing_pid" ]]; then
            echo "[heartbeat-watcher] PID file is empty — cleaning up."
            rm -f "$PID_FILE"
            exit 0
        fi
        if kill -0 "$existing_pid" 2>/dev/null; then
            kill "$existing_pid"
            rm -f "$PID_FILE"
            echo "[heartbeat-watcher] Stopped (pid=$existing_pid)."
        else
            echo "[heartbeat-watcher] Process $existing_pid not found — cleaning up stale PID file."
            rm -f "$PID_FILE"
        fi
        ;;

    status)
        if [[ ! -f "$PID_FILE" ]]; then
            echo "[heartbeat-watcher] Not running (no PID file)."
            exit 1
        fi
        existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            echo "[heartbeat-watcher] Running (pid=$existing_pid, log=$DAEMON_LOG)."
            exit 0
        else
            echo "[heartbeat-watcher] Not running (stale PID file, pid=$existing_pid)."
            rm -f "$PID_FILE"
            exit 1
        fi
        ;;

    *)
        echo "Usage: $0 {start|stop|status}" >&2
        echo "" >&2
        echo "  start   — start the heartbeat watcher daemon in the background" >&2
        echo "  stop    — stop the running daemon" >&2
        echo "  status  — show whether the daemon is running" >&2
        exit 1
        ;;
esac
