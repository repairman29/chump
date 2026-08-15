#!/usr/bin/env bash
# scripts/coord/halt-status.sh — RESILIENT-326
#
# Board instrument for the halt-organ registry (docs/process/HALT_ORGAN_REGISTRY.md).
# Reads the LIVE state each registered organ can put the fleet into and prints a
# loud, unmissable banner when any of them is currently halting the fleet. This
# is the fix for the "silent SPOF" evidence in RESILIENT-326: the back-pressure
# breaker halted production for hours on 2026-08-14 with no instrument anywhere
# that made the halt visible at a glance.
#
# Checks (mirrors the registry table):
#   1. AUTONOMY_LEVEL  — fleet kill-switch at 0 (or missing/corrupt, fail-closed)
#   2. fleet-paused     — conductor pause sentinel present
#   3. worker units     — back-pressure breaker's disabled workers (systemd, opt-in)
#
# Env overrides (all test hooks, so this is runnable off-host and in CI):
#   CHUMP_AUTON_FILE            default ~/.chump/AUTONOMY_LEVEL
#   CHUMP_FLEET_PAUSE_FILE      default <repo>/.chump/fleet-paused
#   CHUMP_HALT_STATUS_SYSTEMD_PROBE 1 = run the systemd worker-unit probe (default),
#     0 = skip it. Auto-skipped off-Linux / when systemctl is unavailable.
#
# Exit codes:
#   0  no organ is currently halting the fleet
#   1  at least one organ is halting the fleet (banner printed to stdout)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AUTON_FILE="${CHUMP_AUTON_FILE:-$HOME/.chump/AUTONOMY_LEVEL}"
PAUSE_FILE="${CHUMP_FLEET_PAUSE_FILE:-$REPO_ROOT/.chump/fleet-paused}"

active=()

# ── 1. fleet kill-switch ─────────────────────────────────────────────────────
auton="$(cat "$AUTON_FILE" 2>/dev/null || echo "")"
if [[ -z "$auton" || "$auton" == "0" || ! "$auton" =~ ^[0-9]+$ ]]; then
    active+=("AUTONOMY_LEVEL=${auton:-<missing>} (kill-switch closed, fail-closed) — file: $AUTON_FILE")
fi

# ── 2. conductor pause sentinel ──────────────────────────────────────────────
if [[ -f "$PAUSE_FILE" ]]; then
    reason="$(cat "$PAUSE_FILE" 2>/dev/null | head -c 200 || echo "")"
    active+=("fleet-paused sentinel present ($PAUSE_FILE): ${reason:-<no reason recorded>}")
fi

# ── 3. back-pressure breaker: disabled worker units (systemd, best-effort) ──
if [[ "${CHUMP_HALT_STATUS_SYSTEMD_PROBE:-1}" == "1" ]] && command -v systemctl >/dev/null 2>&1; then
    running="$(systemctl list-units 2>/dev/null | grep -c 'chump-worker@[0-9].*running' || echo 0)"
    if [[ "$running" == "0" ]]; then
        active+=("no chump-worker@N.service units running (systemd)")
    fi
fi

if (( ${#active[@]} > 0 )); then
    echo "════════════════════════════════════════════════════════════════"
    echo "🛑 HALT ACTIVE — ${#active[@]} organ(s) currently halting the fleet"
    for a in "${active[@]}"; do
        echo "  - $a"
    done
    echo "See docs/process/HALT_ORGAN_REGISTRY.md for the auto-recovery path per organ."
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi

echo "[halt-status] no organ currently halting the fleet"
exit 0
