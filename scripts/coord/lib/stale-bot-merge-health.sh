#!/usr/bin/env bash
# stale-bot-merge-health.sh — INFRA-1531
#
# bot-merge.sh writes .chump-locks/bot-merge-<pid>.health on startup and
# removes it in its EXIT trap (_bm_cleanup). When a bot-merge process is
# killed hard enough to skip the trap (OOM, SIGKILL, host reboot), the
# health file lingers forever — and queue-health-monitor.sh keeps firing
# ALERT kind=bot_merge_hung against a pid that no longer exists.
#
# Real signal (2026-08-28): pid=91790 health file from 22h earlier kept
# triggering bot_merge_hung every 30min; 11 stale files across 4 worktrees
# had to be cleaned up by hand.
#
# Source this file, then call:
#   reap_stale_bot_merge_health <lock_dir> [emit_ambient=0|1] [ambient_path]
#
# Removes any bot-merge-*.health whose pid fails `kill -0`. With
# emit_ambient=1, appends kind=bot_merge_health_reaped {pid, age_hours,
# machine} to ambient_path (default: <lock_dir>/ambient.jsonl) per reap.

[[ -n "${_CHUMP_STALE_BOT_MERGE_HEALTH_LIB:-}" ]] && return 0
_CHUMP_STALE_BOT_MERGE_HEALTH_LIB=1

reap_stale_bot_merge_health() {
    local lock_dir="$1"
    local emit_ambient="${2:-0}"
    local ambient_path="${3:-${lock_dir}/ambient.jsonl}"

    [[ -d "$lock_dir" ]] || return 0

    local lib_dir; lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ "$emit_ambient" == "1" && -f "$lib_dir/ambient-write.sh" ]]; then
        # shellcheck source=ambient-write.sh
        source "$lib_dir/ambient-write.sh"
    fi

    local machine
    machine="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    local now_epoch; now_epoch="$(date -u +%s)"

    local f
    for f in "$lock_dir"/bot-merge-*.health; do
        [[ -e "$f" ]] || continue

        local pid
        pid="$(grep -o '"pid":[0-9]*' "$f" 2>/dev/null | head -1 | grep -o '[0-9]*' || true)"
        [[ -z "$pid" ]] && continue

        # Still alive — leave it.
        kill -0 "$pid" 2>/dev/null && continue

        local started_at start_epoch age_hours
        started_at="$(grep -o '"started_at":"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*:"//;s/"$//')"
        start_epoch="$(date -u -d "$started_at" +%s 2>/dev/null \
            || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null \
            || echo "$now_epoch")"
        age_hours=$(( (now_epoch - start_epoch) / 3600 ))

        rm -f "$f" 2>/dev/null || true

        if [[ "$emit_ambient" == "1" ]]; then
            local line
            line="$(printf '{"ts":"%s","kind":"bot_merge_health_reaped","pid":%s,"age_hours":%s,"machine":"%s"}' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pid" "$age_hours" "$machine")"
            if command -v _ambient_write >/dev/null 2>&1; then
                _ambient_write "$ambient_path" "$line"
            else
                printf '%s\n' "$line" >> "$ambient_path" 2>/dev/null || true
            fi
        fi
    done
}
