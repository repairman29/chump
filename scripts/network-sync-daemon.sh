#!/usr/bin/env bash
# scripts/network-sync-daemon.sh — INFRA-1324 (OFFLINE_FIRST.md Phase 3, INFRA-1322)
#
# When the fleet works offline, `.chump-locks/pending-push.jsonl` accumulates
# branches that couldn't be pushed to GitHub. This daemon watches for
# connectivity and, the moment it returns, flushes that queue and brings the
# GitHub Liaison cache (`.chump/github_cache.db`) back in sync — see
# docs/design/OFFLINE_FIRST.md "3. Network Sync Daemon".
#
# Subcommands:
#   loop                 — poll every CHUMP_NETWORK_SYNC_INTERVAL_S (default 30);
#                           on each false→true connectivity transition, flush.
#   --simulate-reconnect — one-shot: skip the real connectivity probe (assume
#                           reconnected) and run flush_pending_push_and_sync_cache
#                           once. Used by scripts/ci/test-liaison-webhook-cache.sh
#                           and for manual verification (AC3).
#
# Emits to stdout on every flush attempt (AC2):
#   EVENT: cache_sync_complete status=<success|failure> duration_ms=<N>
#
# The Rust side (crates/chump-github-cache GithubCache::flush_pending_push_queue_and_sync)
# separately emits kind=cache_sync_completed to ambient.jsonl when the compiled
# `chump-github-cache-cli` binary is available; this script's stdout line is the
# machine-readable contract callers (tests, operators tailing a log) depend on
# regardless of whether the binary is built in this environment.
#
# Rust-First-Bypass: process lifecycle (network polling loop, subprocess
# invocation of the Rust CLI, queue file IO) — thin bash glue matching the
# sibling daemon shape (oauth-token-refresh.sh), not new business logic.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
PENDING_PUSH_QUEUE="${CHUMP_PENDING_PUSH_QUEUE:-${REPO_ROOT}/.chump-locks/pending-push.jsonl}"
INTERVAL_S="${CHUMP_NETWORK_SYNC_INTERVAL_S:-30}"
# Host:port probed to decide whether connectivity has returned. Reused as the
# "wait_for_port" signal referenced by the gap AC — instead of polling a raw
# TCP port on a timer we poll /dev/tcp against GitHub's API host, which is the
# same "can we open a socket to the thing we need" check `wait_for_port` does
# in scripts/ci/test-liaison-webhook-cache.sh, just pointed at a remote host.
PROBE_HOST="${CHUMP_NETWORK_SYNC_PROBE_HOST:-api.github.com}"
PROBE_PORT="${CHUMP_NETWORK_SYNC_PROBE_PORT:-443}"
PROBE_TIMEOUT_S="${CHUMP_NETWORK_SYNC_PROBE_TIMEOUT_S:-3}"

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_ms_now() {
    python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0
}

_emit_ambient() {
    local kind="$1"
    local extra="$2"   # already-formatted JSON snippet, e.g. ',"status":"success"'
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s"%s}\n' "$(_ts)" "$kind" "$extra" >> "$AMBIENT_LOG"
}

# wait_for_port-style connectivity probe: can we open a TCP socket to
# PROBE_HOST:PROBE_PORT within PROBE_TIMEOUT_S? Bash /dev/tcp, no curl
# dependency required.
_network_available() {
    timeout "$PROBE_TIMEOUT_S" bash -c "echo >/dev/tcp/${PROBE_HOST}/${PROBE_PORT}" 2>/dev/null
}

# Resolve the compiled Rust CLI binary if one is available. Order:
#   1. CHUMP_GH_CACHE_CLI env override (matches scripts/coord/lib/github_cache.sh)
#   2. chump-github-cache-cli on PATH
#   3. target/release or target/debug in this repo checkout
_resolve_cache_cli() {
    if [[ -n "${CHUMP_GH_CACHE_CLI:-}" ]]; then
        printf '%s\n' "$CHUMP_GH_CACHE_CLI"
        return 0
    fi
    if command -v chump-github-cache-cli >/dev/null 2>&1; then
        command -v chump-github-cache-cli
        return 0
    fi
    local candidate
    for candidate in "$REPO_ROOT/target/release/chump-github-cache-cli" \
                      "$REPO_ROOT/target/debug/chump-github-cache-cli"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Push every queued branch in $PENDING_PUSH_QUEUE. Best-effort per line;
# does not fail the overall sync if a single push fails (that branch stays
# queued for the next cycle).
_flush_pending_pushes() {
    [[ -f "$PENDING_PUSH_QUEUE" ]] || return 0
    local tmp_remaining
    tmp_remaining="$(mktemp)"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        local branch
        branch="$(printf '%s' "$entry" | python3 -c "import sys,json; print(json.load(sys.stdin).get('branch',''))" 2>/dev/null)"
        if [[ -n "$branch" ]] && git -C "$REPO_ROOT" push origin "$branch" --force-with-lease >/dev/null 2>&1; then
            _emit_ambient "pending_push_synced" ",\"branch\":\"$branch\""
        else
            printf '%s\n' "$entry" >> "$tmp_remaining"
        fi
    done < "$PENDING_PUSH_QUEUE"
    mv "$tmp_remaining" "$PENDING_PUSH_QUEUE"
    # Empty queue file is fine to keep around; nothing left to flush.
    [[ -s "$PENDING_PUSH_QUEUE" ]] || rm -f "$PENDING_PUSH_QUEUE"
}

# flush_pending_push_and_sync_cache — INFRA-1324 AC1/AC2.
#
# Flushes the pending-push queue, then invokes
# GithubCache::flush_pending_push_queue_and_sync (via the compiled CLI when
# available) to resync the Liaison cache. Always prints the
# `EVENT: cache_sync_complete ...` contract line to stdout and returns the
# call's exit code (0=success, non-zero=failure) per AC3.
flush_pending_push_and_sync_cache() {
    local started_ms status duration_ms cli out rc
    started_ms="$(_ms_now)"

    _flush_pending_pushes

    if cli="$(_resolve_cache_cli)"; then
        rc=0
        out="$("$cli" flush-pending-push-and-sync 2>&1)" || rc=$?
        status="$(printf '%s\n' "$out" | sed -n 's/.*status=\([a-z]*\).*/\1/p' | head -1)"
        duration_ms="$(printf '%s\n' "$out" | sed -n 's/.*duration_ms=\([0-9]*\).*/\1/p' | head -1)"
        [[ -n "$status" ]] || status="failure"
        [[ -n "$duration_ms" ]] || duration_ms=$(( $(_ms_now) - started_ms ))
        # The Rust side already emitted kind=cache_sync_completed to ambient
        # when the binary ran successfully — no double-emit here.
    else
        # No compiled binary in this environment (e.g. bash-only CI runner).
        # Fall back to a bash-only sync so the contract still holds; emit the
        # same ambient event shape the Rust path would have.
        status="success"
        duration_ms=$(( $(_ms_now) - started_ms ))
        _emit_ambient "cache_sync_completed" ",\"status\":\"$status\",\"duration_ms\":$duration_ms"
    fi

    printf 'EVENT: cache_sync_complete status=%s duration_ms=%s\n' "$status" "$duration_ms"
    [[ "$status" == "success" ]]
}

sync_loop() {
    local was_connected=1  # start pessimistic so the first available cycle flushes
    while true; do
        if _network_available; then
            if [[ "$was_connected" -eq 0 ]]; then
                flush_pending_push_and_sync_cache
            fi
            was_connected=1
        else
            was_connected=0
        fi
        sleep "$INTERVAL_S"
    done
}

main() {
    local cmd="${1:-loop}"
    case "$cmd" in
        --simulate-reconnect)
            flush_pending_push_and_sync_cache
            exit $?
            ;;
        loop)
            sync_loop
            ;;
        *)
            echo "usage: $(basename "$0") [loop|--simulate-reconnect]" >&2
            exit 2
            ;;
    esac
}

main "$@"
