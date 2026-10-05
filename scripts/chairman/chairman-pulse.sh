#!/usr/bin/env bash
# chairman-pulse.sh — RESILIENT-331. Board power-output readout.
#
# WHY THIS EXISTS. journalctl on any organ's systemd unit shows only "Finished
# <description>" — LIVENESS (is it turning), never EFFECTIVENESS (did it make
# power). pr-lander ran 9x, rot-reaper ran 3x, farmer ran 176x, organ-watchdog
# ran 18x — and from the systemd log alone it was impossible to tell whether
# ANY of them merged a PR, closed a rot, healed an organ, or rescued a worker.
# Meanwhile real outcomes proved ineffectiveness: #3792 rotted DIRTY 13h while
# the reaper ran; a worker spun 58x/90s while active; green PRs sat unmerged
# while the lander ran. A dashboard of green lights with no lap times.
#
# This script is the fix: it reads the structured per-cycle outcome events
# organs already emit to ambient.jsonl (kind=reaper_run, pr_lander_beat,
# organ_watchdog_tick, farmer_heartbeat, ...), SUMS them into a power-output
# view per organ, and flags any organ that ran but accomplished nothing over
# CHUMP_CHAIRMAN_PULSE_ZOMBIE_MIN_CYCLES consecutive cycles ("zombie-alive" —
# the alarm no liveness check can raise). It also measures core-loop
# throughput (gap claimed -> gap shipped) DIRECTLY by pairing gap_claimed /
# gap_shipped events on gap_id, instead of proxying it with ships/hour.
#
# Usage:
#   bash scripts/chairman/chairman-pulse.sh [--window-hours N] [--json]
#
# Env:
#   CHUMP_AMBIENT_LOG                       — override ambient.jsonl path
#   CHUMP_CHAIRMAN_PULSE_WINDOW_H            — window in hours (default 24)
#   CHUMP_CHAIRMAN_PULSE_ZOMBIE_MIN_CYCLES   — min cycles before a zero-power
#                                               organ is flagged zombie-alive
#                                               (default 3)
#
# Exit: 0 normal, 2 when >=1 organ is flagged zombie-alive this run (mirrors
# the underlying Python aggregator's exit code — a readout you can also wire
# into a gate). --fail-on-zombie is a no-op kept for callers that only check
# 0-vs-nonzero and want that intent documented at the call site.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
WINDOW_H="${CHUMP_CHAIRMAN_PULSE_WINDOW_H:-24}"
ZOMBIE_MIN_CYCLES="${CHUMP_CHAIRMAN_PULSE_ZOMBIE_MIN_CYCLES:-3}"
JSON_OUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-hours) WINDOW_H="$2"; shift 2 ;;
        --zombie-min-cycles) ZOMBIE_MIN_CYCLES="$2"; shift 2 ;;
        --json) JSON_OUT=1; shift ;;
        --fail-on-zombie) shift ;;  # no-op: exit code already carries this (see header)
        *) echo "[chairman-pulse] unknown arg: $1" >&2; shift ;;
    esac
done

[[ -f "$AMBIENT_LOG" ]] || { echo "[chairman-pulse] no ambient log at $AMBIENT_LOG — nothing to read"; exit 0; }

mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true

python3 "$SELF_DIR/chairman_pulse.py" \
    --ambient "$AMBIENT_LOG" \
    --window-hours "$WINDOW_H" \
    --zombie-min-cycles "$ZOMBIE_MIN_CYCLES" \
    --json-out "$JSON_OUT" \
    --repo-root "$REPO_ROOT"
exit $?
