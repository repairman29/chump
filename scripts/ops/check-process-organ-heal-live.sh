#!/usr/bin/env bash
# check-process-organ-heal-live.sh — INFRA-3650 (PEER-HEAL-03), AC4.
#
# LIVE-tier check. Run this ON the target node itself (e.g. closetjunky) —
# it does not attempt any remote SSH; it asserts against the node's own
# ambient.jsonl and its own process table. Per this gap's AC4: "verified by
# systemctl/pgrep on the TARGET node, never merged=running" — a green PR/CI
# run proves the code is correct, NOT that the loop is alive on any specific
# machine. Only this script, run there, proves that.
#
# Checks:
#   1. process-organ-heal's own loop is running (pgrep on the installed
#      wrapper, or the systemd unit is active if this host uses systemd).
#   2. A kind=organ_watchdog_tick with source=process-organ-heal appeared in
#      ambient.jsonl within the last cycle-interval
#      (CHUMP_PROCESS_ORGAN_HEAL_INTERVAL_S, default 300s) x 2 (grace).
#   3. almanac-vision-keeper is running (pgrep on its script path).
#
# Full operator walkthrough (prerequisites, expected output, what to do if a
# check is red): docs/process/PROCEDURES/verify-process-organ-heal-live.md
#
# Usage:
#   scripts/ops/check-process-organ-heal-live.sh
#
# Env:
#   CHUMP_AMBIENT_LOG            — override ambient.jsonl path (wins over discovery)
#   CHUMP_NODE_DIR               — legacy override: $CHUMP_NODE_DIR/repo/.chump-locks/ambient.jsonl
#   CHUMP_PROCESS_ORGAN_HEAL_INTERVAL_S — expected tick cadence (default 300)
#
# Exit codes: 0 = all live, 1 = one or more checks failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Default discovery order: explicit override > $CHUMP_REPO_ROOT (the same env
# var process-organ-heal.sh itself honors, and what chump-process-organ-heal's
# systemd drop-in sets — a worktree checkout running this script may not be
# the checkout the service actually writes ambient.jsonl from, so trust the
# service's own env over self-location) > this checkout's own repo root (same
# trick process-organ-heal.sh uses when CHUMP_REPO_ROOT is unset — this
# script lives in a tracked repo, so SCRIPT_DIR/../.. IS the repo root
# wherever it's checked out) > legacy $CHUMP_NODE_DIR/repo shape, for
# back-compat with any install that still uses that layout. Ground truth
# from a real closetjunky run (2026-08-22): systemd's
# chump-process-organ-heal.service sets CHUMP_REPO_ROOT=/home/jeff/Projects/chump,
# NOT $HOME/.chumpnode/repo — the old hardcoded default silently produced a
# false NOT-LIVE verdict here, and self-location alone reproduces the same
# false negative when the script is run from a *different* worktree than the
# one the service points at.
REPO_ROOT_GUESS="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODE_DIR="${CHUMP_NODE_DIR:-$HOME/.chumpnode}"
if [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then
    AMBIENT_LOG="$CHUMP_AMBIENT_LOG"
elif [[ -n "${CHUMP_REPO_ROOT:-}" && -f "$CHUMP_REPO_ROOT/.chump-locks/ambient.jsonl" ]]; then
    AMBIENT_LOG="$CHUMP_REPO_ROOT/.chump-locks/ambient.jsonl"
elif [[ -f "$REPO_ROOT_GUESS/.chump-locks/ambient.jsonl" ]]; then
    AMBIENT_LOG="$REPO_ROOT_GUESS/.chump-locks/ambient.jsonl"
else
    AMBIENT_LOG="$NODE_DIR/repo/.chump-locks/ambient.jsonl"
fi
INTERVAL="${CHUMP_PROCESS_ORGAN_HEAL_INTERVAL_S:-300}"
GRACE=$(( INTERVAL * 2 ))

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }

fail=0

echo "=== check-process-organ-heal-live (INFRA-3650, AC4) ==="

# ── 1. the heal loop itself ─────────────────────────────────────────────────
# Two valid supervision shapes, both installed by tracked repo mechanisms:
#   (a) chump-node-install.sh's common_organs — a persistent while-true
#       wrapper process (pgrep-visible the whole time).
#   (b) organ-manifest.txt + install-fleet-node.sh's oneshot+timer pair
#       (chump-process-organ-heal.service/.timer, INFRA-3650 live-tier fix)
#       — same shape as chump-organ-watchdog.service itself: the .service
#       is legitimately "inactive (dead)" BETWEEN timer fires, so liveness
#       is proven by the TIMER being active, not the oneshot service.
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet chump-process-organ-heal 2>/dev/null; then
    ok "process-organ-heal: systemd unit chump-process-organ-heal active"
elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet chump-process-organ-heal.timer 2>/dev/null; then
    ok "process-organ-heal: systemd timer chump-process-organ-heal.timer active (oneshot+timer shape)"
elif command -v pgrep >/dev/null 2>&1 && pgrep -f "scripts/ops/process-organ-heal.sh" >/dev/null 2>&1; then
    ok "process-organ-heal: wrapper process running (pgrep)"
else
    no "process-organ-heal: NOT running (no active systemd unit/timer, no pgrep match)"
    fail=1
fi

# ── 2. fresh organ_watchdog_tick from this source ───────────────────────────
if [[ ! -f "$AMBIENT_LOG" ]]; then
    no "ambient.jsonl not found at $AMBIENT_LOG"
    fail=1
else
    last_tick_ts="$(grep '"source":"process-organ-heal"' "$AMBIENT_LOG" 2>/dev/null \
        | grep '"kind":"organ_watchdog_tick"' \
        | tail -1 \
        | sed -E 's/.*"ts":"([^"]+)".*/\1/')"
    if [[ -z "$last_tick_ts" ]]; then
        no "no organ_watchdog_tick (source=process-organ-heal) found in $AMBIENT_LOG"
        fail=1
    else
        now_epoch="$(date -u +%s)"
        last_epoch="$(date -u -d "$last_tick_ts" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_tick_ts" +%s 2>/dev/null || echo 0)"
        age=$(( now_epoch - last_epoch ))
        if [[ "$age" -le "$GRACE" ]]; then
            ok "organ_watchdog_tick fresh (${age}s ago, threshold ${GRACE}s): $last_tick_ts"
        else
            no "organ_watchdog_tick STALE (${age}s ago, threshold ${GRACE}s): $last_tick_ts"
            fail=1
        fi
    fi
fi

# ── 3. almanac-vision-keeper (AC3) ──────────────────────────────────────────
if command -v pgrep >/dev/null 2>&1 && pgrep -f "scripts/ops/almanac-vision-keeper.sh" >/dev/null 2>&1; then
    ok "almanac-vision-keeper: running (pgrep)"
else
    no "almanac-vision-keeper: NOT running"
    fail=1
fi

echo
if [[ "$fail" == 0 ]]; then
    printf '\033[42m LIVE ✓ \033[0m process-organ-heal + almanac-vision-keeper confirmed on this node\n'
else
    printf '\033[41m NOT LIVE \033[0m — fix the ✗ above; re-run scripts/setup/chump-node-install.sh if the organ was never installed\n'
fi
exit "$fail"
