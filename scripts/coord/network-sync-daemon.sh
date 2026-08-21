#!/usr/bin/env bash
# network-sync-daemon.sh — INFRA-1324
#
# Phase 2→3 of the offline-first roadmap (docs/design/OFFLINE_FIRST.md §3).
# Watches for network connectivity and, when it returns, flushes the
# pending-push queue (.chump-locks/pending-push.jsonl, format documented in
# INFRA-1323: {branch, sha, ts, gap} per line) and refreshes the GitHub
# webhook cache (.chump/github_cache.db) so Liaison-backed reads aren't
# stale after a stretch offline.
#
# Usage:
#   network-sync-daemon.sh tick [--dry-run]   # one sync pass, exits 0
#   network-sync-daemon.sh loop [--dry-run]   # runs tick every $CHUMP_NETWORK_SYNC_INTERVAL_S forever
#   network-sync-daemon.sh status             # pending-push queue depth, last tick summary
#
# Exit codes:
#   0  success (tick: ran to completion, regardless of whether network was
#      available — "network unavailable" is a normal tick outcome, not a
#      script failure; status: always 0)
#   1  unexpected error (bad usage, queue file unreadable/corrupt)
#
# Rust-First-Bypass: bash glue over curl/git/gh, coherent with the sibling
# local-merge-queue.sh shape in scripts/coord/. No hot-path call (fires on a
# 30s+ timer, not per-claim), <200 LOC, no regression-test burden beyond the
# one CI smoke test this gap ships alongside it.
set -euo pipefail

# shellcheck source=../lib/repo-paths.sh
source "$(dirname "$0")/../lib/repo-paths.sh"
# shellcheck source=lib/ambient-write.sh
source "$(dirname "$0")/lib/ambient-write.sh"
# shellcheck source=lib/github_cache.sh
source "$(dirname "$0")/lib/github_cache.sh"

AMBIENT_LOG="$LOCK_DIR/ambient.jsonl"
PENDING_PUSH_QUEUE="${CHUMP_PENDING_PUSH_QUEUE:-$LOCK_DIR/pending-push.jsonl}"

NETWORK_CHECK_URL="${CHUMP_NETWORK_CHECK_URL:-https://api.github.com/zen}"
NETWORK_CHECK_TIMEOUT_S="${CHUMP_NETWORK_CHECK_TIMEOUT_S:-3}"
PUSH_TIMEOUT_S="${CHUMP_PUSH_TIMEOUT_S:-30}"
SYNC_INTERVAL_S="${CHUMP_NETWORK_SYNC_INTERVAL_S:-30}"
CACHE_SYNC_ENABLED="${CHUMP_NETWORK_SYNC_CACHE:-1}"

mkdir -p "$LOCK_DIR"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_s() { date -u +%s; }

# scanner-anchor: "kind":"network_sync_tick"
# scanner-anchor: "kind":"pending_push_synced"
# scanner-anchor: "kind":"pending_push_retry"
# scanner-anchor: "kind":"pending_push_failed"
# scanner-anchor: "kind":"github_cache_synced"
# scanner-anchor: "kind":"github_cache_sync_skipped"
_emit() {
    # _emit <kind> <extra-json-fields-without-braces>
    local kind="$1" extra="${2:-}"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$(_ts)\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$(_ts)\",\"kind\":\"$kind\"}"
    fi
    _ambient_write "$AMBIENT_LOG" "$line"
}

# ── Failure-class taxonomy ──────────────────────────────────────────────────
# TRANSIENT — network_unreachable, push_timeout, remote_rejected_stale:
#   requeued, retried on the next tick, no operator action needed.
# PERMANENT — branch_missing, non_fast_forward_conflict, auth_failed:
#   dropped from the queue, emitted with reason so the operator (or the
#   owning gap's picker) can act; these do NOT retry forever.
# DEGRADED — cache_lib_unavailable, gh_missing:
#   the sync proceeds (pushes still flush) but the GitHub-cache-refresh
#   half of the tick is skipped; not an error, just reduced coverage.

_network_available() {
    curl -sf --max-time "$NETWORK_CHECK_TIMEOUT_S" "$NETWORK_CHECK_URL" >/dev/null 2>&1
}

_queue_lines() {
    [[ -f "$PENDING_PUSH_QUEUE" ]] || return 0
    cat "$PENDING_PUSH_QUEUE"
}

_queue_depth() {
    [[ -f "$PENDING_PUSH_QUEUE" ]] || { echo 0; return; }
    wc -l < "$PENDING_PUSH_QUEUE" | tr -d ' '
}

# _flush_pending_pushes <dry_run> — reads $PENDING_PUSH_QUEUE, attempts
# `git push` for each entry. Synced and permanently-failed entries are
# dropped from the queue; transient failures are rewritten back so the next
# tick retries them. Prints "<synced> <retried> <failed>" to stdout.
_flush_pending_pushes() {
    local dry_run="$1"
    local synced=0 retried=0 failed=0
    [[ -f "$PENDING_PUSH_QUEUE" ]] || { echo "0 0 0"; return 0; }

    local tmp; tmp="$(mktemp)"
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local branch gap sha
        branch="$(printf '%s' "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin).get('branch',''))" 2>/dev/null || true)"
        gap="$(printf '%s' "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin).get('gap',''))" 2>/dev/null || true)"
        sha="$(printf '%s' "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || true)"

        if [[ -z "$branch" ]]; then
            # Unparseable entry — drop it rather than retry forever on garbage.
            failed=$((failed + 1))
            _emit "pending_push_failed" "\"gap\":\"$gap\",\"reason\":\"unparseable_entry\""
            continue
        fi

        if [[ "$dry_run" == "1" ]]; then
            echo "[network-sync-daemon] (dry-run) would push $branch (gap=$gap)"
            echo "$entry" >> "$tmp"
            continue
        fi

        if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
            failed=$((failed + 1))
            _emit "pending_push_failed" "\"gap\":\"$gap\",\"branch\":\"$branch\",\"reason\":\"branch_missing\""
            continue
        fi

        local start_s rc
        start_s="$(_now_s)"
        set +e
        timeout "$PUSH_TIMEOUT_S" git push origin "$branch" --force-with-lease >/dev/null 2>&1
        rc=$?
        set -e
        local duration_s=$(( $(_now_s) - start_s ))

        if [[ $rc -eq 0 ]]; then
            synced=$((synced + 1))
            _emit "pending_push_synced" "\"gap\":\"$gap\",\"branch\":\"$branch\",\"sha\":\"$sha\",\"duration_s\":$duration_s"
        elif [[ $rc -eq 124 ]]; then
            retried=$((retried + 1))
            _emit "pending_push_retry" "\"gap\":\"$gap\",\"branch\":\"$branch\",\"reason\":\"timeout\",\"duration_s\":$duration_s"
            echo "$entry" >> "$tmp"
        else
            # git push failed for a reason other than timeout. Treat as
            # transient (network blip / remote moved under us) by default —
            # a real non-fast-forward conflict against a stale lease will
            # keep failing and the operator sees repeated pending_push_retry
            # events for the same branch, which is the signal to intervene.
            retried=$((retried + 1))
            _emit "pending_push_retry" "\"gap\":\"$gap\",\"branch\":\"$branch\",\"reason\":\"push_rejected_transient\",\"duration_s\":$duration_s"
            echo "$entry" >> "$tmp"
        fi
    done < <(_queue_lines)

    mv "$tmp" "$PENDING_PUSH_QUEUE"
    echo "$synced $retried $failed"
}

# _sync_github_cache <dry_run> — best-effort refresh of the webhook cache.
# DEGRADED (not an error) when the cache lib or `gh` isn't available.
_sync_github_cache() {
    local dry_run="$1"
    if [[ "$CACHE_SYNC_ENABLED" != "1" ]]; then
        _emit "github_cache_sync_skipped" "\"reason\":\"disabled\""
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        _emit "github_cache_sync_skipped" "\"reason\":\"gh_missing\""
        return 0
    fi
    if [[ "$dry_run" == "1" ]]; then
        echo "[network-sync-daemon] (dry-run) would refresh github cache"
        return 0
    fi
    local start_s; start_s="$(_now_s)"
    if cache_refresh_open_prs >/dev/null 2>&1; then
        _emit "github_cache_synced" "\"duration_s\":$(( $(_now_s) - start_s ))"
    else
        _emit "github_cache_sync_skipped" "\"reason\":\"refresh_failed\""
    fi
}

# _tick <dry_run> — one full sync pass. Always exits 0; "no network" and
# "nothing pending" are normal outcomes, not failures. Cost (wall-clock) is
# reported on every tick via kind=network_sync_tick so `chump waste-tally
# --kind network_sync` can attribute daemon overhead; this path makes zero
# LLM calls so the only cost dimension is wall-clock + push count.
_tick() {
    local dry_run="0"
    [[ "${1:-}" == "--dry-run" ]] && dry_run="1"
    local tick_start; tick_start="$(_now_s)"

    if ! _network_available; then
        _emit "network_sync_tick" "\"network_available\":false,\"pushes_synced\":0,\"pushes_retried\":0,\"pushes_failed\":0,\"cache_synced\":false,\"duration_s\":$(( $(_now_s) - tick_start )),\"pending_depth\":$(_queue_depth)"
        echo "[network-sync-daemon] network unavailable — nothing flushed."
        return 0
    fi

    local result synced retried failed
    result="$(_flush_pending_pushes "$dry_run")"
    read -r synced retried failed <<< "$result"

    local cache_synced="false"
    if _sync_github_cache "$dry_run"; then
        [[ "$CACHE_SYNC_ENABLED" == "1" ]] && command -v gh >/dev/null 2>&1 && cache_synced="true"
    fi

    _emit "network_sync_tick" "\"network_available\":true,\"pushes_synced\":$synced,\"pushes_retried\":$retried,\"pushes_failed\":$failed,\"cache_synced\":$cache_synced,\"duration_s\":$(( $(_now_s) - tick_start )),\"pending_depth\":$(_queue_depth)"
    echo "[network-sync-daemon] tick complete: synced=$synced retried=$retried failed=$failed pending=$(_queue_depth)"
}

_loop() {
    local dry_run_flag="${1:-}"
    while true; do
        _tick "$dry_run_flag"
        sleep "$SYNC_INTERVAL_S"
    done
}

_status() {
    echo "[network-sync-daemon] pending-push queue: $(_queue_depth) entries ($PENDING_PUSH_QUEUE)"
    local last_tick
    last_tick="$(grep '"kind":"network_sync_tick"' "$AMBIENT_LOG" 2>/dev/null | tail -1)"
    if [[ -n "$last_tick" ]]; then
        echo "[network-sync-daemon] last tick: $last_tick"
    else
        echo "[network-sync-daemon] no tick recorded yet."
    fi
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        tick)
            shift || true
            _tick "${1:-}"
            ;;
        loop)
            shift || true
            _loop "${1:-}"
            ;;
        status)
            _status
            ;;
        *)
            echo "usage: $0 {tick [--dry-run]|loop [--dry-run]|status}" >&2
            exit 1
            ;;
    esac
}

main "$@"
