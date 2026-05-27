#!/usr/bin/env bash
# scripts/coord/binary-refresh-event-watcher.sh — INFRA-2007
#
# Event-driven watcher: subscribes to kind=binary_main_updated events in
# ambient.jsonl and triggers scripts/setup/refresh-runner-binary.sh immediately
# when a merge lands on main. Eliminates the W-002 binary-cache-lag class
# structurally (zero lag from merge to binary install on the happy path).
#
# Hybrid design:
#   Primary: event-driven (this script, watches ambient.jsonl tail via fswatch/tail -F)
#   Fallback: 5-min cron (install-refresh-runner-binary-launchd.sh keeps the poll)
#   Rate-limit: only 1 rebuild per CHUMP_BINARY_EVENT_RATE_LIMIT_S (default 60s)
#
# macOS: uses fswatch (brew install fswatch) if available, else falls back to
#        tail -F polling (portable, slightly higher latency but no dep required).
#
# Emits ambient kinds:
#   binary_refresh_triggered_event   — rebuild triggered by event-driven path
#   binary_event_watcher_rate_limited — rebuild skipped (within rate window)
#   binary_event_watcher_no_tool     — fswatch absent; polling fallback active
#
# Bypass: CHUMP_BINARY_EVENT_WATCHER=0 exits immediately (launchd can still
#         run the cron path).
#
# Stopped by SIGTERM (launchd Unload). Sends SIGTERM to child refresh on stop.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-/Users/jeffadkins/Projects/Chump}"
AMBIENT="${CHUMP_BINARY_WATCHER_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
REFRESH_SCRIPT="${CHUMP_BINARY_REFRESH_SCRIPT:-$REPO_ROOT/scripts/setup/refresh-runner-binary.sh}"
RATE_LIMIT_S="${CHUMP_BINARY_EVENT_RATE_LIMIT_S:-60}"
LOG_DIR="$REPO_ROOT/.chump-locks/binary-refresh-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/event-watcher.log"

emit() {
    local kind="$1" extra="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind $extra" >> "$LOG"
}

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# Bypass
if [[ "${CHUMP_BINARY_EVENT_WATCHER:-1}" == "0" ]]; then
    log "BYPASS: CHUMP_BINARY_EVENT_WATCHER=0"
    exit 0
fi

if [[ ! -x "$REFRESH_SCRIPT" ]]; then
    log "FATAL: $REFRESH_SCRIPT not found or not executable"
    exit 1
fi

if [[ ! -f "$AMBIENT" ]]; then
    log "WARN: ambient.jsonl not found at $AMBIENT — waiting for it to appear"
    # Wait up to 30s for ambient.jsonl to be created (race at startup)
    for _w in $(seq 1 30); do
        sleep 1
        [[ -f "$AMBIENT" ]] && break
    done
    if [[ ! -f "$AMBIENT" ]]; then
        log "FATAL: ambient.jsonl still absent after 30s — exiting"
        exit 1
    fi
fi

# Rate-limit state: track last rebuild time
_last_rebuild_ts=0

# Graceful shutdown: kill refresh child if running
_refresh_pid=""
_shutdown() {
    log "SIGTERM received — shutting down event watcher"
    [[ -n "$_refresh_pid" ]] && kill "$_refresh_pid" 2>/dev/null || true
    exit 0
}
trap '_shutdown' TERM INT

# ── Core: process a line from ambient.jsonl ──────────────────────────────────
_on_ambient_line() {
    local line="$1"
    # Fast path: skip lines that don't contain binary_main_updated
    [[ "$line" == *'"kind":"binary_main_updated"'* ]] || return 0

    local now
    now="$(date +%s)"
    local since=$(( now - _last_rebuild_ts ))

    if [[ $since -lt $RATE_LIMIT_S ]]; then
        local wait_s=$(( RATE_LIMIT_S - since ))
        log "RATE-LIMIT: binary_main_updated received but last rebuild was ${since}s ago (< ${RATE_LIMIT_S}s limit); skipping (wait ${wait_s}s)"
        emit binary_event_watcher_rate_limited "\"since_last_s\":${since},\"rate_limit_s\":${RATE_LIMIT_S}"
        return 0
    fi

    log "EVENT: binary_main_updated detected — triggering immediate refresh"
    emit binary_refresh_triggered_event "\"trigger\":\"binary_main_updated\",\"since_last_s\":${since}"

    # Run refresh in background so we keep watching the stream
    _last_rebuild_ts="$now"
    bash "$REFRESH_SCRIPT" >> "$LOG" 2>&1 &
    _refresh_pid=$!
    log "Refresh started (pid=$_refresh_pid)"
    # Wait in background; clear pid when done
    (wait "$_refresh_pid" 2>/dev/null; _refresh_pid=""; log "Refresh complete (rc=$?)") &
}

# ── Watch strategy: fswatch preferred, tail -F fallback ──────────────────────
log "Starting INFRA-2007 event-driven binary refresh watcher (rate_limit=${RATE_LIMIT_S}s)"

if command -v fswatch >/dev/null 2>&1; then
    log "Using fswatch (zero-overhead event-driven path)"
    # fswatch fires on any write to ambient.jsonl; we then read new tail lines
    # via tail to get the actual content. This is the correct macOS FSEvents pattern.
    _fswatcher_fifo="$(mktemp -u /tmp/chump-bw-XXXXXX)"
    mkfifo "$_fswatcher_fifo"
    trap 'rm -f "$_fswatcher_fifo"; _shutdown' TERM INT

    # Run fswatch in background writing to fifo
    fswatch --one-per-batch --latency 0.5 "$AMBIENT" > "$_fswatcher_fifo" &
    _fswatch_pid=$!

    # Tail to read actual lines appended since we started
    _tail_fifo="$(mktemp -u /tmp/chump-bt-XXXXXX)"
    mkfifo "$_tail_fifo"
    tail -F -n 0 "$AMBIENT" > "$_tail_fifo" 2>/dev/null &
    _tail_pid=$!

    # Wait for fswatch events and drain new lines from ambient.jsonl
    while IFS= read -r _fs_event <"$_fswatcher_fifo"; do
        # Drain all buffered lines from the tail fifo
        while IFS= read -t 0.1 -r _line <"$_tail_fifo"; do
            _on_ambient_line "$_line"
        done
    done

    kill "$_fswatch_pid" "$_tail_pid" 2>/dev/null || true
    rm -f "$_fswatcher_fifo" "$_tail_fifo"
else
    log "fswatch not found — using tail -F polling fallback"
    emit binary_event_watcher_no_tool "\"note\":\"fswatch absent; install via brew install fswatch for zero-overhead path\""

    # Portable: tail -F, process each new line
    tail -F -n 0 "$AMBIENT" 2>/dev/null | while IFS= read -r _line; do
        _on_ambient_line "$_line"
    done
fi
