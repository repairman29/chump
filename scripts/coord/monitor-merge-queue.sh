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
: "${MONITOR_INTERVAL_S:=60}"
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
# Source chump_gh wrapper for rate-limit awareness + ambient recording
source "$SCRIPT_DIR/lib/github.sh"
# INFRA-2464: cache-first PR queue reads (cache_query_pr_queue) + REST-not-
# GraphQL queued-run counts, so this 10s-cadence daemon doesn't burn `gh run
# list` / `gh pr list` (GraphQL) every tick.
source "$SCRIPT_DIR/lib/github_cache.sh"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")"

iso8601() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ; }

emit() {
    local line="$1"
    printf '%s\n' "$line" >> "$AMBIENT"
}

_timeout_cmd() {
    # Job-control-based timeout, not GNU timeout(1)/gtimeout(1) — this
    # helper's callers (gh_query_queued_workflows / gh_query_auto_merge_prs)
    # pass `chump_gh`, a bash *function* sourced from lib/github.sh. GNU
    # `timeout` execs a new process image and can't resolve a function name
    # on PATH, so `timeout 8 chump_gh ...` fails immediately with rc=127
    # ("No such file or directory") — silently turning every poll into
    # queue_health_check_failed even though nothing actually timed out or
    # errored. Backgrounding the call and racing a sleep-then-kill watcher
    # against it works for both functions and binaries since it stays in
    # the same shell (no exec).
    local secs="$1"
    shift
    "$@" &
    local target_pid=$!
    ( sleep "$secs"; kill -TERM "$target_pid" 2>/dev/null ) &
    local watcher_pid=$!
    local rc=0
    wait "$target_pid" 2>/dev/null || rc=$?
    kill "$watcher_pid" 2>/dev/null
    wait "$watcher_pid" 2>/dev/null
    return "$rc"
}

gh_query_queued_workflows() {
    # Count GitHub Actions runs with status=queued. INFRA-2464: `gh run list`
    # is a GraphQL call; the equivalent REST endpoint
    # (actions/runs?status=queued) hits the REST bucket instead, which stays
    # healthy during GraphQL exhaustion. Timeout after 8s.
    local repo
    repo="$(_cache_repo_nwo 2>/dev/null || true)"
    if [[ -z "$repo" ]]; then
        echo "ERROR"
        return
    fi
    CHUMP_GH_CALL_CRITICALITY=background _timeout_cmd 8 chump_gh api \
        "repos/$repo/actions/runs?status=queued&per_page=100" \
        --jq '.total_count' 2>/dev/null || echo "ERROR"
}
gh_query_auto_merge_prs() {
    # Count open PRs with auto-merge armed. INFRA-2464: cache-first via the
    # webhook-fed pr_state table (cache_query_pr_queue); falls back to the
    # REST-backed `gh pr list` only when the cache is empty/stale.
    local rows
    rows="$(cache_query_pr_queue 2>/dev/null || true)"
    if [[ -n "$rows" ]]; then
        printf '%s\n' "$rows" | awk -F'\t' '$5 == 1' | wc -l | tr -d ' '
        return
    fi
    CHUMP_GH_CALL_CRITICALITY=background _timeout_cmd 8 chump_gh pr list --state open --json autoMergeRequest \
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
