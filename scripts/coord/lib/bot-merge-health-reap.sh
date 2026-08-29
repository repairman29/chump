#!/usr/bin/env bash
# bot-merge-health-reap.sh — INFRA-1531: reap stale .chump-locks/bot-merge-*.health files.
#
# bot-merge.sh's EXIT trap normally removes its own health file, but a hard
# kill (SIGKILL, OOM, host crash) skips the trap entirely and the file
# lingers forever — queue-health-monitor.sh then reads a decades-old
# last_heartbeat_at and fires a bogus `bot_merge_hung` ALERT every cycle.
# Precedent: pid=91790's health file from 22h earlier (started_at
# 2026-05-15T20:22Z) kept re-triggering the alert; 11 stale files had to be
# cleaned up by hand across 4 worktrees.
#
# Source this file, then call:
#   reap_stale_bot_merge_health <lock_dir> [ambient_file]
#
# For each .chump-locks/bot-merge-<pid>.health whose pid is not alive
# (`kill -0 $pid` fails), removes the file and — if an ambient_file is
# given — appends kind=bot_merge_health_reaped {pid, age_hours, machine}.
#
# Prints one "reaped pid=<pid> age_hours=<n>" line per file removed.

_bmhr_machine() {
    if [[ -n "${CHUMP_MACHINE_LABEL:-}" ]]; then
        echo "$CHUMP_MACHINE_LABEL"
    elif [[ -r /etc/hostname ]]; then
        tr -d '[:space:]' </etc/hostname
    else
        hostname 2>/dev/null || echo "unknown"
    fi
}

reap_stale_bot_merge_health() {
    local lock_dir="${1:?lock_dir required}"
    local ambient_file="${2:-}"
    local hf pid started_at now_epoch started_epoch age_hours machine

    [[ -d "$lock_dir" ]] || return 0
    machine="$(_bmhr_machine)"
    now_epoch="$(date -u +%s)"

    shopt -s nullglob
    for hf in "$lock_dir"/bot-merge-*.health; do
        pid="$(basename "$hf" .health)"
        pid="${pid#bot-merge-}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue

        # Alive? Skip.
        if kill -0 "$pid" 2>/dev/null; then
            continue
        fi

        started_at="$(sed -n 's/.*"started_at":"\([^"]*\)".*/\1/p' "$hf" 2>/dev/null | head -1)"
        started_epoch=""
        if [[ -n "$started_at" ]]; then
            started_epoch="$(date -u -d "$started_at" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$started_at" +%s 2>/dev/null || true)"
        fi
        if [[ -n "$started_epoch" ]]; then
            age_hours="$(( (now_epoch - started_epoch) / 3600 ))"
        else
            age_hours=0
        fi

        rm -f "$hf" 2>/dev/null || true
        echo "reaped pid=${pid} age_hours=${age_hours}"

        if [[ -n "$ambient_file" ]]; then
            local ts json_line
            ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            json_line="$(printf '{"ts":"%s","kind":"bot_merge_health_reaped","pid":%s,"age_hours":%s,"machine":"%s"}' \
                "$ts" "$pid" "$age_hours" "$machine")"
            if declare -f _ambient_write >/dev/null 2>&1; then
                _ambient_write "$ambient_file" "$json_line"
            else
                printf '%s\n' "$json_line" >> "$ambient_file" 2>/dev/null || true
            fi
        fi
    done
    shopt -u nullglob
}
