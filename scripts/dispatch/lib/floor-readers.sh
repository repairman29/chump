#!/usr/bin/env bash
# scripts/dispatch/lib/floor-readers.sh — INFRA-2008 (THE FLOOR Phase 1+2 wiring)
#
# Source this from a worker/agent prelude, then call `chump_floor_read`.
# It exports two env vars for the caller (and any subagent it spawns) to
# branch on:
#
#   CHUMP_FLOOR_TEMP=COLD|WARM|HOT   — from `chump health --temp` (INFRA-1992)
#   CHUMP_FLEET_HOLD=true|false      — from scripts/coord/fleet-hold-check.sh (INFRA-1987 Phase 2)
#
# Usage:
#   source "$REPO_ROOT/scripts/dispatch/lib/floor-readers.sh"
#   chump_floor_read
#   if [[ "$CHUMP_FLEET_HOLD" == "true" ]]; then
#       # pivot to triage/docs work; do not claim shipping gaps
#   fi
#   if [[ "$CHUMP_FLOOR_TEMP" == "HOT" ]]; then
#       # restrict to xs/docs gaps; refuse env-mutating work
#   fi
#
# This function does not exit or print — it only sets/exports variables so
# callers keep full control over logging/telemetry.

chump_floor_read() {
    local repo_root="${REPO_ROOT:-${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"

    # (1) Fleet-hold — INFRA-1987 Phase 2. exit 2 = hold active.
    CHUMP_FLEET_HOLD="false"
    local hold_check="${repo_root}/scripts/coord/fleet-hold-check.sh"
    if [[ -x "$hold_check" ]]; then
        if ! bash "$hold_check" --quiet 2>/dev/null; then
            CHUMP_FLEET_HOLD="true"
        fi
    fi

    # (2) Floor temperature — INFRA-1992. exit 0=COLD, 1=WARM, 2=HOT.
    CHUMP_FLOOR_TEMP="COLD"
    if chump health --temp >/dev/null 2>&1; then
        CHUMP_FLOOR_TEMP="COLD"
    else
        local rc=$?
        case "$rc" in
            1) CHUMP_FLOOR_TEMP="WARM" ;;
            2) CHUMP_FLOOR_TEMP="HOT" ;;
            *) CHUMP_FLOOR_TEMP="COLD" ;;  # unknown / chump unavailable — proceed normally
        esac
    fi

    export CHUMP_FLEET_HOLD CHUMP_FLOOR_TEMP
}
