#!/usr/bin/env bash
# scripts/coord/monitor-merge-queue.sh — CREDIBLE-068
#
# Continuous daemon: every 10 s polls the GitHub merge queue depth and emits
# kind=merge_queue_health to .chump-locks/ambient.jsonl.
#
# Metrics:
#   queued_workflows    — GH Actions runs currently queued (status=queued)
#   auto_merge_prs      — open PRs with autoMergeRequest enabled
#   queue_saturation_pct — (queued_workflows / QUEUE_ALERT_THRESHOLD) * 100
#   backpressure_recommended — true when saturation > 70 %
#
# Thresholds (overridable via env):
#   QUEUE_ALERT_THRESHOLD    — saturation denominator, default 50
#   QUEUE_CRITICAL_THRESHOLD — advisory only (logged), default 100
#   MONITOR_INTERVAL_S       — poll interval, default 10
#
# Fallback: if gh API call times out / fails, emits kind=queue_health_check_failed
# (advisory; fleet keeps running).
#
# Usage:
#   # Run as daemon (Ctrl-C to stop):
#   bash scripts/coord/monitor-merge-queue.sh
#
#   # One-shot (for testing):
#   MONITOR_ONCE=1 bash scripts/coord/monitor-merge-queue.sh
#
# Bypass: CHUMP_MERGE_QUEUE_MONITOR=0 exits 0 immediately.

set -uo pipefail

: "${MONITOR_INTERVAL_S:=10}"
: "${QUEUE_ALERT_THRESHOLD:=50}"
: "${QUEUE_CRITICAL_THRESHOLD:=100}"
: "${MONITOR_ONCE:=0}"
: "${CHUMP_MERGE_QUEUE_MONITOR:=1}"

if [[ "$CHUMP_MERGE_QUEUE_MONITOR" == "0" ]]; then
    echo "[monitor-merge-queue] disabled via CHUMP_MERGE_QUEUE_MONITOR=0" >&2
    exit 0
fi

# Resolve repo root + ambient log.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")"

iso8601() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ; }

emit() {
    local line="$1"
    printf '%s\n' "$line" >> "$AMBIENT"
}

_timeout_cmd() {
    # Use GNU timeout / gtimeout / perl fallback on macOS.
    local secs="$1"
    shift
    if command -v timeout &>/dev/null; then
        timeout "$secs" "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$secs" "$@"
    else
        # No timeout available — run directly (best-effort).
        "$@"
    fi
}

gh_query_queued_workflows() {
    # Count GitHub Actions runs with status=queued. Timeout after 8s.
    _timeout_cmd 8 gh run list --status queued --json databaseId --limit 100 \
        --jq 'length' 2>/dev/null || echo "ERROR"
}

gh_query_auto_merge_prs() {
    # Count open PRs with autoMergeRequest set. Uses REST search.
    _timeout_cmd 8 gh pr list --state open --json autoMergeRequest \
        --jq '[.[] | select(.autoMergeRequest != null)] | length' 2>/dev/null \
    || echo "ERROR"
}

run_once() {
    local ts
    ts="$(iso8601)"

    local queued_raw auto_merge_raw
    queued_raw="$(gh_query_queued_workflows)"
    auto_merge_raw="$(gh_query_auto_merge_prs)"

    # Check for errors.
    if [[ "$queued_raw" == "ERROR" ]] || [[ "$auto_merge_raw" == "ERROR" ]]; then
        emit "{\"ts\":\"$ts\",\"kind\":\"queue_health_check_failed\",\"note\":\"gh api call failed or timed out; fleet assumes queue healthy\"}"
        echo "[monitor-merge-queue] ⚠ gh API error at $ts — emitted queue_health_check_failed" >&2
        return
    fi

    local queued="${queued_raw//[^0-9]/}"
    local auto_merge="${auto_merge_raw//[^0-9]/}"
    queued="${queued:-0}"
    auto_merge="${auto_merge:-0}"

    # Compute saturation (integer math; bash doesn't do float).
    local sat_pct=0
    if [[ "$QUEUE_ALERT_THRESHOLD" -gt 0 ]]; then
        sat_pct=$(( queued * 100 / QUEUE_ALERT_THRESHOLD ))
    fi

    # Clamp to 100 for display purposes.
    local sat_display=$sat_pct
    [[ $sat_display -gt 100 ]] && sat_display=100

    local backpressure="false"
    [[ $sat_pct -gt 70 ]] && backpressure="true"

    # Advisory: log when crossing critical threshold.
    if [[ $queued -ge $QUEUE_CRITICAL_THRESHOLD ]]; then
        echo "[monitor-merge-queue] CRITICAL: $queued queued workflows ≥ QUEUE_CRITICAL_THRESHOLD ($QUEUE_CRITICAL_THRESHOLD)" >&2
    fi

    local line
    line="{\"ts\":\"$ts\",\"kind\":\"merge_queue_health\",\"queued_workflows\":$queued,\"auto_merge_prs\":$auto_merge,\"queue_saturation_pct\":$sat_display,\"backpressure_recommended\":$backpressure}"
    emit "$line"
    echo "$line"
}

echo "[monitor-merge-queue] starting (interval=${MONITOR_INTERVAL_S}s alert_threshold=${QUEUE_ALERT_THRESHOLD})" >&2

if [[ "$MONITOR_ONCE" == "1" ]]; then
    run_once
    exit 0
fi

while true; do
    run_once
    sleep "$MONITOR_INTERVAL_S"
done
