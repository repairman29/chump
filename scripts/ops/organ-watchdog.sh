#!/usr/bin/env bash
# scripts/ops/organ-watchdog.sh — INFRA-3595
#
# WHY THIS EXISTS. Operator directive: the board must NOT hand-restart ATC
# organs (no helicopter parenting). Today none self-heals: chump-sla-scorecard
# .service failed on 2026-08-11 with nothing to bring it back. The systemd
# failure mode here is specifically start-limit-hit — a oneshot unit fired by
# a timer that fails a few times in a row trips systemd's default
# StartLimitBurst, and the unit sits `failed (Result: start-limit-hit)`
# forever: every subsequent timer fire is silently refused until something
# runs `systemctl reset-failed <unit>`. This watchdog is that something.
#
# Algorithm, every cycle:
#   1. List every chump-*.service unit systemd knows about.
#   2. For each one whose ActiveState=failed: `systemctl reset-failed <unit>`
#      then `systemctl restart <unit>` (oneshots) — clears the start-limit
#      latch and re-fires the unit immediately rather than waiting for the
#      next timer tick.
#   3. Do the same for chump-*.timer units that are enabled but inactive
#      (a timer can itself be disabled by a failed daemon-reload elsewhere).
#   4. Emit kind=organ_self_healed per unit healed (observable proof of
#      self-heal, no human step) and kind=organ_watchdog_tick every run
#      (heartbeat, mirrors main-health-watchdog's success-path emit) so a
#      dead watchdog is itself visible via the standard reaper-heartbeat
#      pattern.
#
# Usage:
#   scripts/ops/organ-watchdog.sh              # scan + heal, real systemctl
#   scripts/ops/organ-watchdog.sh --dry-run     # report only, no restart
#
# Test hooks (used by scripts/ci/test-organ-watchdog.sh):
#   CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN — path to a stubbed `systemctl`
#   CHUMP_AMBIENT_LOG                  — override ambient.jsonl path
#
# Exit codes:
#   0  normal (whether or not any organ needed healing)
#   1  systemctl unavailable (non-Linux dev box, or not installed) — quiet
#      no-op, this is expected on a macOS operator laptop
#   2  internal failure (reset-failed/restart itself failed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

SYSTEMCTL_BIN="${CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN:-systemctl}"

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

if ! command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
    echo "[organ-watchdog] systemctl unavailable ($SYSTEMCTL_BIN not found) — no-op (expected off the helsinki node)"
    exit 1
fi

healed=0
scan_fail=0

# ── 1. Failed chump-*.service units ─────────────────────────────────────────
FAILED_SERVICES="$("$SYSTEMCTL_BIN" list-units --all --type=service --state=failed --plain --no-legend 'chump-*.service' 2>/dev/null | awk '{print $1}')"

if [[ -n "$FAILED_SERVICES" ]]; then
    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue
        echo "[organ-watchdog] FAILED: $unit"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[organ-watchdog]   (dry-run) would reset-failed + restart $unit"
            continue
        fi
        if ! "$SYSTEMCTL_BIN" reset-failed "$unit" 2>&1; then
            echo "[organ-watchdog]   ERROR: reset-failed $unit failed" >&2
            # scanner-anchor: "kind":"organ_self_heal_failed"  (INFRA-3595;
            # fires when reset-failed/restart itself errors — a genuinely
            # broken organ, not just a start-limit latch)
            emit organ_self_heal_failed "\"unit\":\"$unit\",\"step\":\"reset-failed\""
            scan_fail=1
            continue
        fi
        if ! "$SYSTEMCTL_BIN" restart "$unit" 2>&1; then
            echo "[organ-watchdog]   ERROR: restart $unit failed" >&2
            emit organ_self_heal_failed "\"unit\":\"$unit\",\"step\":\"restart\""
            scan_fail=1
            continue
        fi
        echo "[organ-watchdog]   healed $unit"
        # scanner-anchor: "kind":"organ_self_healed"  (INFRA-3595; fires when
        # the watchdog resets + restarts a failed chump-* organ with no
        # human step — the self-heal proof the board polls for)
        emit organ_self_healed "\"unit\":\"$unit\",\"action\":\"reset-failed+restart\""
        healed=$((healed + 1))
    done <<< "$FAILED_SERVICES"
fi

# ── 2. Enabled-but-inactive chump-*.timer units ─────────────────────────────
ALL_TIMERS="$("$SYSTEMCTL_BIN" list-unit-files --type=timer --plain --no-legend 'chump-*.timer' 2>/dev/null | awk '$2=="enabled"{print $1}')"

if [[ -n "$ALL_TIMERS" ]]; then
    while IFS= read -r timer; do
        [[ -z "$timer" ]] && continue
        if "$SYSTEMCTL_BIN" is-active --quiet "$timer" 2>/dev/null; then
            continue
        fi
        echo "[organ-watchdog] INACTIVE (but enabled): $timer"
        if [[ "$DRY_RUN" == "1" ]]; then
            echo "[organ-watchdog]   (dry-run) would start $timer"
            continue
        fi
        if ! "$SYSTEMCTL_BIN" start "$timer" 2>&1; then
            echo "[organ-watchdog]   ERROR: start $timer failed" >&2
            emit organ_self_heal_failed "\"unit\":\"$timer\",\"step\":\"start-timer\""
            scan_fail=1
            continue
        fi
        echo "[organ-watchdog]   healed $timer"
        emit organ_self_healed "\"unit\":\"$timer\",\"action\":\"start-timer\""
        healed=$((healed + 1))
    done <<< "$ALL_TIMERS"
fi

# Heartbeat — always emit so a dead watchdog is itself observable (paired
# with scripts/ops/reaper-heartbeat-watchdog.sh's cadence-grading pattern).
# scanner-anchor: "kind":"organ_watchdog_tick"  (INFRA-3595; emitted every
# cycle, success or no-op — proof the watchdog itself is alive)
emit organ_watchdog_tick "\"healed\":$healed,\"dry_run\":$DRY_RUN"

echo "[organ-watchdog] cycle complete: healed=$healed dry_run=$DRY_RUN"

[[ "$scan_fail" == "1" ]] && exit 2
exit 0
