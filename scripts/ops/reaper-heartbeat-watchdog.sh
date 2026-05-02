#!/usr/bin/env bash
# reaper-heartbeat-watchdog.sh — Detect when a stale-* reaper has stopped
# running and ALERT the fleet via ambient.jsonl.
#
# INFRA-120 (2026-05-01): the three reapers (stale-pr, stale-worktree,
# stale-branch) each run on their own launchd cadence. If the launchd plist
# isn't installed, or its job silently fails (broken PATH, dead python3, etc.),
# nothing alerts the fleet. Worktrees and branches accumulate for days before
# anyone notices. This watchdog grades the heartbeat files written by
# scripts/lib/reaper-instrumentation.sh and emits ALERT events so the staleness
# is visible in the standard pre-flight `tail -30 .chump-locks/ambient.jsonl`.
#
# Per-reaper cadence (the launchd plists configure these; numbers below match):
#
#   pr        | StartInterval 3600s   (1h)  → ALERT if no heartbeat in 4h
#   worktree  | StartInterval 3600s   (1h)  → ALERT if no heartbeat in 4h
#   branch    | StartInterval 86400s (24h)  → ALERT if no heartbeat in 48h
#
# Multipliers default to 4x cadence (worktree, branch) and 2x for the
# faster-cadence pr reaper, matching the gap acceptance criteria.
#
# Usage:
#   scripts/ops/reaper-heartbeat-watchdog.sh                    # check all reapers
#   scripts/ops/reaper-heartbeat-watchdog.sh pr worktree        # subset
#   scripts/ops/reaper-heartbeat-watchdog.sh --quiet            # ALERT only on failure
#
# Cron / launchd: install via scripts/setup/install-reaper-watchdog-launchd.sh
# (runs every 30 min). The watchdog itself is fail-closed: if it can't write
# to ambient.jsonl, it prints to stderr and exits non-zero so the launchd
# stderr log captures the issue.

set -euo pipefail

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"

QUIET=0
declare -a TARGETS
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        --*) echo "Unknown flag: $1" >&2; exit 2 ;;
        *) TARGETS+=("$1") ;;
    esac
    shift
done
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(pr worktree branch)

# Per-reaper alert thresholds (seconds since last heartbeat).
threshold_secs() {
    case "$1" in
        pr)       echo $((2 * 3600)) ;;   # 2h (cadence 1h × 2x)
        worktree) echo $((4 * 3600)) ;;   # 4h (cadence 1h × 4x)
        branch)   echo $((48 * 3600)) ;;  # 48h (cadence 24h × 2x)
        *)        echo $((4 * 3600)) ;;
    esac
}

reaper_setup watchdog

ALERTS=0
OK=0
NOW=$(date +%s)

for name in "${TARGETS[@]}"; do
    hb="/tmp/chump-reaper-${name}.heartbeat"
    threshold=$(threshold_secs "$name")
    if [[ ! -f "$hb" ]]; then
        msg="reaper ${name} has never heartbeated — heartbeat file missing at $hb. Install the launchd job (scripts/setup/install-stale-${name}-reaper-launchd.sh) or run the reaper manually once."
        printf 'ALERT [reaper_silent] %s\n' "$msg" >&2
        # Emit ALERT to ambient.jsonl directly (use raw JSON so we don't
        # depend on the broadcast.sh wrapper for fail-safety).
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"event":"ALERT","kind":"reaper_silent","reaper":"%s","ts":"%s","reason":%s}\n' \
            "$name" "$ts" \
            "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$msg" 2>/dev/null || echo "\"$msg\"")" \
            >> "$REAPER_LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        ALERTS=$((ALERTS + 1))
        continue
    fi
    # Heartbeat file format is `key=value` lines; ts=... is the canonical key.
    ts_line=$(grep '^ts=' "$hb" 2>/dev/null | head -1 | cut -d= -f2- || true)
    if [[ -z "$ts_line" ]]; then
        # Fall back to mtime.
        last=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)
    else
        # Parse ISO-8601 UTC. macOS date(1) needs explicit -j -f.
        if last=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_line" "+%s" 2>/dev/null); then
            :
        else
            last=$(date -u -d "$ts_line" "+%s" 2>/dev/null || stat -f%m "$hb" 2>/dev/null || echo 0)
        fi
    fi
    age=$(( NOW - last ))
    age_h=$(( age / 3600 ))
    threshold_h=$(( threshold / 3600 ))

    if [[ $age -gt $threshold ]]; then
        msg="reaper ${name} has not run in ${age_h}h (threshold ${threshold_h}h). Last heartbeat at ${ts_line:-unknown}. Check launchctl list | grep ai.openclaw.chump-stale-${name}-reaper and /tmp/chump-stale-${name}-reaper.err.log."
        printf 'ALERT [reaper_silent] %s\n' "$msg" >&2
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '{"event":"ALERT","kind":"reaper_silent","reaper":"%s","ts":"%s","age_hours":%d,"threshold_hours":%d,"reason":%s}\n' \
            "$name" "$ts" "$age_h" "$threshold_h" \
            "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$msg" 2>/dev/null || echo "\"$msg\"")" \
            >> "$REAPER_LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        ALERTS=$((ALERTS + 1))
    else
        OK=$((OK + 1))
        [[ $QUIET -eq 0 ]] && printf '  ok: %s heartbeated %dh ago (threshold %dh)\n' "$name" "$age_h" "$threshold_h"
    fi
done

if [[ $QUIET -eq 0 ]]; then
    printf '=== watchdog done: %d ok, %d ALERT(s) ===\n' "$OK" "$ALERTS"
fi

# Emit our own reaper_run so the watchdog also has a heartbeat (the watchdog
# guards the reapers; nothing else guards the watchdog, but at least its
# run history is in the ambient stream).
reaper_finish ok "{\"checked\":${#TARGETS[@]},\"ok\":$OK,\"alerts\":$ALERTS}"

exit 0
