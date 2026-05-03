#!/usr/bin/env bash
# scripts/ops/disk-pressure-watchdog.sh — INFRA-338
#
# Preemptive disk-space watchdog. Caught 2026-05-03 03:00 UTC: parallel
# fleet + Task subagent batches accumulated >100GB of cargo target/ in
# .claude/worktrees/. Disk hit ENOSPC. /private/tmp/claude-501/ could
# no longer write Bash tool output → every command failed silently for
# ~10 min until manual cleanup.
#
# This watchdog runs periodically (recommended: every 5 min via launchd),
# checks free space, and:
#   - >= 20% free   → silent exit
#   - 10-20% free   → emit ALERT kind=disk_low to ambient.jsonl
#   - < 10% free    → emit ALERT kind=disk_critical AND trigger
#                     stale-worktree-reaper --execute unconditionally
#                     (the hourly cron may not fire fast enough during
#                     a fleet-spike; pre-emptive cleanup is the move)
#
# The watchdog is read-only above the 10% threshold, so it's safe to
# invoke frequently. Below 10%, it acts (reaper) — but the reaper itself
# has multiple safety guards (cooldown, lease check, log freshness).
#
# Usage:
#   bash scripts/ops/disk-pressure-watchdog.sh             # one-shot check
#   bash scripts/ops/disk-pressure-watchdog.sh --dry-run   # never act
#
# Env:
#   CHUMP_DISK_WARN_PCT       (default 20) free-pct below which to emit warn
#   CHUMP_DISK_CRITICAL_PCT   (default 10) free-pct below which to act
#   CHUMP_DISK_TARGET_FS      (default /)  filesystem to monitor

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TARGET_FS="${CHUMP_DISK_TARGET_FS:-/}"
WARN_PCT="${CHUMP_DISK_WARN_PCT:-20}"
CRITICAL_PCT="${CHUMP_DISK_CRITICAL_PCT:-10}"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# Macos df: -P portable output, -k for KB.
read -r _ _ _ avail used_pct _ < <(df -Pk "$TARGET_FS" | tail -1)
used_pct_num="${used_pct%\%}"
free_pct=$((100 - used_pct_num))

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[disk-watchdog %s] %s\n' "$(ts)" "$*"; }

emit_ambient() {
    local kind="$1"; local body="$2"
    local f="$REPO_ROOT/.chump-locks/ambient.jsonl"
    [[ -d "$REPO_ROOT/.chump-locks" ]] || return 0
    printf '{"ts":"%s","session":"disk-watchdog","worktree":"%s","event":"ALERT","kind":"%s","body":"%s"}\n' \
        "$(ts)" "$(basename "$REPO_ROOT")" "$kind" "$body" >> "$f"
}

if [[ "$free_pct" -ge "$WARN_PCT" ]]; then
    log "OK: ${free_pct}% free on $TARGET_FS (>= ${WARN_PCT}% threshold)"
    exit 0
fi

if [[ "$free_pct" -ge "$CRITICAL_PCT" ]]; then
    body="disk pressure: ${free_pct}% free on ${TARGET_FS} (warn threshold ${WARN_PCT}%)"
    log "WARN: $body"
    [[ $DRY -eq 0 ]] && emit_ambient "disk_low" "$body"
    exit 0
fi

# Critical: < CRITICAL_PCT% free
body="DISK CRITICAL: ${free_pct}% free on ${TARGET_FS} (critical threshold ${CRITICAL_PCT}%)"
log "CRITICAL: $body"

if [[ $DRY -eq 1 ]]; then
    log "DRY-RUN: would emit ALERT + trigger reaper"
    exit 0
fi

emit_ambient "disk_critical" "$body"

# Trigger reaper unconditionally (pre-empt the hourly cooldown).
REAPER="$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"
if [[ -x "$REAPER" ]]; then
    log "triggering stale-worktree-reaper --execute"
    bash "$REAPER" --execute 2>&1 | tail -3
else
    log "WARN: $REAPER not found — manual cleanup required"
fi

# Re-check after reap and emit recovery event if better.
read -r _ _ _ _ used_pct2 _ < <(df -Pk "$TARGET_FS" | tail -1)
free_pct2=$((100 - ${used_pct2%\%}))
if [[ "$free_pct2" -gt "$free_pct" ]]; then
    body2="recovered: ${free_pct}% → ${free_pct2}% free on ${TARGET_FS}"
    log "$body2"
    emit_ambient "disk_recovered" "$body2"
fi
