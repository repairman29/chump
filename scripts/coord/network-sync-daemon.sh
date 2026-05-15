#!/usr/bin/env bash
# shellcheck disable=SC1091  # lib/ sources use dynamic $SCRIPT_DIR — resolved at runtime
#
# network-sync-daemon.sh — monitors network connectivity and flushes pending-push queue
#
# When working offline, commits pile up locally. This daemon:
#   1. Periodically checks if GitHub is reachable
#   2. When connected, flushes pending pushes from `.chump-locks/pending-push.jsonl`
#   3. Optionally syncs the GitHub liaison cache (INFRA-1317, INFRA-1318)
#   4. Emits ambient.jsonl events for observability and cost tracking
#
# Part of OFFLINE_FIRST.md Phase 3. Works with local merge queue (INFRA-1321) and
# auto-detect offline mode (INFRA-1323).
#
# Usage:
#   scripts/coord/network-sync-daemon.sh                     # foreground (for testing)
#   scripts/coord/network-sync-daemon.sh --daemonize        # background (launchd)
#   scripts/coord/network-sync-daemon.sh --check-once       # one cycle (cron-safe)
#
# Environment:
#   CHUMP_SYNC_INTERVAL_S    — sleep between cycles (default 30s)
#   CHUMP_SYNC_RETRY_MAX     — max retries for transient failures (default 3)
#   CHUMP_SYNC_LIAISON_REFRESH — sync GitHub cache on reconnect (default 1=yes)
#   CHUMP_SYNC_CACHE_MIN_AGE_S — skip cache refresh if <N seconds old (default 300s)
#
# Ambient events emitted:
#   - network_sync_cycle_start: cycle begins
#   - network_sync_network_available / network_sync_network_unavailable: state changes only
#   - pending_push_flushed: successful push
#   - pending_push_failed_transient: transient failure, will retry
#   - pending_push_failed_permanent: permanent failure, skipped
#   - network_sync_cache_refresh_start / network_sync_cache_refresh_done
#   - network_sync_cycle_done: cycle metrics
#   - network_sync_cost: API call cost tracking
#
# Exit codes:
#   0 — success (daemon exited cleanly or single cycle succeeded)
#   1 — fatal error (e.g., bad arguments)
#   2 — cycle failed (network unavailable, queue processing errors)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/ambient-write.sh
source "$SCRIPT_DIR/lib/ambient-write.sh"

# Configuration
CHUMP_SYNC_INTERVAL_S="${CHUMP_SYNC_INTERVAL_S:-30}"
CHUMP_SYNC_RETRY_MAX="${CHUMP_SYNC_RETRY_MAX:-3}"
CHUMP_SYNC_LIAISON_REFRESH="${CHUMP_SYNC_LIAISON_REFRESH:-1}"
CHUMP_SYNC_CACHE_MIN_AGE_S="${CHUMP_SYNC_CACHE_MIN_AGE_S:-300}"

LOCK_DIR=".chump-locks"
AMBIENT_JSONL="$LOCK_DIR/ambient.jsonl"
PENDING_PUSH_QUEUE="$LOCK_DIR/pending-push.jsonl"
CACHE_TOUCH_FILE="$LOCK_DIR/.network-sync-cache-timestamp"

DAEMONIZE=0
CHECK_ONCE=0
LAST_NETWORK_STATE=""  # Track state changes to emit only on transition
CYCLE_NUMBER=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --daemonize) DAEMONIZE=1 ;;
        --check-once) CHECK_ONCE=1 ;;
        -h|--help)
            sed -n '2,40p' "$0" | grep -E '^#'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
    shift
done

# Helper: emit ambient event (uses lib/ambient-write.sh)
emit_event() {
    local kind="$1"
    shift
    local fields=("$@")

    local json
    json="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"kind\":\"$kind\""
    for field in "${fields[@]}"; do
        json="$json,$field"
    done
    json="$json}"

    _ambient_write "$AMBIENT_JSONL" "$json"
}

# Helper: check if GitHub is reachable (fast, with timeout)
_network_available() {
    curl -sf --max-time 3 https://api.github.com/zen >/dev/null 2>&1
}

# Helper: parse git push error and classify as transient or permanent
classify_push_error() {
    local stderr="$1"

    # Transient errors — retry next cycle
    if echo "$stderr" | grep -qiE "(timeout|ECONNREFUSED|temporarily rate limited|server error|500|502|503|504)"; then
        echo "transient"
        return 0
    fi

    # Permanent errors — give up
    if echo "$stderr" | grep -qiE "(fatal: could not read|permission denied|404 Not Found|fatal: Authentication|401|403|fatal.*not.*found)"; then
        echo "permanent"
        return 0
    fi

    # Unknown — treat as transient to be safe
    echo "transient"
}

# Helper: flush a single pending push entry
flush_push_entry() {
    local entry="$1"
    local branch retry_count error_class

    # Parse JSONL entry: {branch:"...", timestamp:"...", retry_count:N}
    branch=$(echo "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin)['branch'])" 2>/dev/null || echo "")
    retry_count=$(echo "$entry" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('retry_count',0))" 2>/dev/null || echo "0")

    if [[ -z "$branch" ]]; then
        echo "[sync] SKIP: malformed pending-push entry" >&2
        return 1
    fi

    # Attempt push with --force-with-lease (safe rebase)
    local push_stderr
    if push_stderr=$(git push origin "$branch" --force-with-lease 2>&1); then
        # Success
        local sha; sha=$(git rev-parse "$branch" 2>/dev/null || echo "")
        emit_event "pending_push_flushed" "\"branch\":\"$branch\"" "\"sha\":\"$sha\"" "\"retry_count\":$retry_count"
        return 0
    else
        # Failure — classify
        error_class=$(classify_push_error "$push_stderr")
        if [[ "$error_class" == "transient" ]]; then
            emit_event "pending_push_failed_transient" "\"branch\":\"$branch\"" "\"error_class\":\"$error_class\"" "\"retry_count\":$retry_count" "\"error\":\"$(echo "$push_stderr" | head -1 | jq -Rs .)\""
            return 1
        else
            # Permanent — log and skip
            emit_event "pending_push_failed_permanent" "\"branch\":\"$branch\"" "\"error_class\":\"$error_class\"" "\"error\":\"$(echo "$push_stderr" | head -1 | jq -Rs .)\""
            return 2
        fi
    fi
}

# Helper: process pending-push queue
_flush_pending_pushes() {
    local queue="$PENDING_PUSH_QUEUE"
    [[ -f "$queue" ]] || return 0

    local entries_success=0
    local entries_failed=0
    local entries_skipped=0

    local temp_queue="$queue.tmp"
    true > "$temp_queue"  # Start with empty queue

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue

        if flush_push_entry "$entry"; then
            ((entries_success++))
        else
            # Keep failed entry in queue if transient
            if ! echo "$entry" | python3 -c "import sys,json; d=json.load(sys.stdin); d['retry_count'] = d.get('retry_count', 0) + 1; print(json.dumps(d))" 2>/dev/null >> "$temp_queue"; then
                ((entries_skipped++))
            else
                ((entries_failed++))
            fi
        fi
    done < "$queue"

    # Swap queue (atomic on POSIX filesystems)
    if [[ -s "$temp_queue" ]]; then
        mv "$temp_queue" "$queue"
    else
        rm -f "$temp_queue" "$queue"
    fi

    echo "$entries_success" "$entries_failed" "$entries_skipped"
}

# Helper: sync GitHub cache (Liaison refresh, if enabled and old enough)
_sync_github_cache() {
    [[ "$CHUMP_SYNC_LIAISON_REFRESH" == "1" ]] || return 0

    # Check if cache is fresh enough (avoid thrashing on reconnect)
    if [[ -f "$CACHE_TOUCH_FILE" ]]; then
        local age_s; age_s=$(($(date +%s) - $(stat -f%m "$CACHE_TOUCH_FILE" 2>/dev/null || echo 0)))
        if [[ $age_s -lt $CHUMP_SYNC_CACHE_MIN_AGE_S ]]; then
            emit_event "network_sync_cache_refresh_skipped" "\"reason\":\"age_too_recent\"" "\"age_s\":$age_s"
            return 0
        fi
    fi

    emit_event "network_sync_cache_refresh_start" "\"phase\":\"liaison_poll\""

    # This would call the Liaison polling code (INFRA-1317, INFRA-1318)
    # For now, stub it — the Liaison module is built separately
    local start_ts; start_ts=$(date +%s)
    local entries_updated=0
    local api_calls=0

    # Placeholder: In production, call scripts/coord/github-liaison-refresh.sh or similar
    # which updates .chump/github_cache.db and returns call count
    # For now, assume a minimal fetch:
    if cache_result=$(scripts/coord/github-liaison-refresh.sh --dry-run 2>/dev/null || echo "0 0"); then
        api_calls=$(echo "$cache_result" | awk '{print $1}')
        entries_updated=$(echo "$cache_result" | awk '{print $2}')
    fi

    local elapsed_s=$(($(date +%s) - start_ts))
    emit_event "network_sync_cache_refresh_done" "\"entries_updated\":$entries_updated" "\"api_calls\":$api_calls" "\"elapsed_s\":$elapsed_s"

    # Touch timestamp
    touch "$CACHE_TOUCH_FILE"
}

# Main cycle
_sync_cycle() {
    ((CYCLE_NUMBER++))

    emit_event "network_sync_cycle_start" "\"cycle_number\":$CYCLE_NUMBER"

    local cycle_start_ts; cycle_start_ts=$(date +%s)
    local network_available=0
    local entries_processed=0
    local entries_failed=0
    local git_push_attempts=0
    local cache_api_calls=0

    # Check network
    if _network_available; then
        network_available=1

        # Emit state-change event (only if transitioning from unavailable)
        if [[ "$LAST_NETWORK_STATE" != "available" ]]; then
            emit_event "network_sync_network_available"
            LAST_NETWORK_STATE="available"
        fi

        # Flush pending pushes
        local push_results
        if push_results=$(_flush_pending_pushes); then
            entries_processed=$(echo "$push_results" | awk '{print $1 + $2 + $3}')
            entries_failed=$(echo "$push_results" | awk '{print $2}')
            git_push_attempts=$entries_processed
        fi

        # Sync cache (if enabled)
        _sync_github_cache
    else
        # Network unavailable — emit state-change event only if transitioning from available
        if [[ "$LAST_NETWORK_STATE" != "unavailable" ]]; then
            emit_event "network_sync_network_unavailable"
            LAST_NETWORK_STATE="unavailable"
        fi
    fi

    # Calculate cost
    local cost_category="low"
    [[ $cache_api_calls -gt 5 ]] && cost_category="medium"
    [[ $cache_api_calls -gt 20 ]] && cost_category="high"

    local elapsed_s=$(($(date +%s) - cycle_start_ts))
    emit_event "network_sync_cycle_done" \
        "\"cycle_number\":$CYCLE_NUMBER" \
        "\"network_available\":$network_available" \
        "\"entries_processed\":$entries_processed" \
        "\"entries_failed\":$entries_failed" \
        "\"elapsed_s\":$elapsed_s"

    emit_event "network_sync_cost" \
        "\"cache_api_calls\":$cache_api_calls" \
        "\"git_push_attempts\":$git_push_attempts" \
        "\"cost_category\":\"$cost_category\""

    return 0
}

# Main daemon loop
_daemon_loop() {
    trap '_cleanup' EXIT TERM INT

    while true; do
        if ! _sync_cycle; then
            echo "[sync-daemon] cycle failed" >&2
        fi

        [[ "$CHECK_ONCE" == "1" ]] && break
        sleep "$CHUMP_SYNC_INTERVAL_S"
    done
}

_cleanup() {
    # Optional: clean up resources
    return 0
}

# Main entry
if [[ "$DAEMONIZE" == "1" ]]; then
    # Background mode
    nohup "$0" > "$LOCK_DIR/network-sync-daemon.log" 2>&1 &
    echo $! > "$LOCK_DIR/network-sync-daemon.pid"
    echo "network-sync-daemon started (PID: $(cat "$LOCK_DIR/network-sync-daemon.pid"))"
else
    # Foreground mode
    _daemon_loop
fi
