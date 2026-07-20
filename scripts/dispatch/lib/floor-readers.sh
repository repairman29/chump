#!/usr/bin/env bash
# scripts/dispatch/lib/floor-readers.sh — INFRA-2008 (THE FLOOR Phase 1+2 wire)
#
# Sourced by worker.sh before each claim cycle. Reads the two floor signals
# and exports them so both the worker loop AND any spawned `claude -p`
# subagent inherit the same view of fleet state:
#
#   CHUMP_FLOOR_TEMP   COLD|WARM|HOT   — chump health --temp (INFRA-1992)
#   CHUMP_FLEET_HOLD   true|false      — fleet-hold-check.sh (INFRA-2004)
#
# Usage (see scripts/dispatch/worker.sh prelude):
#   source "$REPO_ROOT/scripts/dispatch/lib/floor-readers.sh"
#   chump_read_floor_signals "$REPO_ROOT" "$AGENT_ID" "$_amb_pre"
#   # then read $CHUMP_FLOOR_TEMP / $CHUMP_FLEET_HOLD / $CHUMP_FLEET_HOLD_ACTIVE

chump_read_floor_signals() {
    local _repo_root="$1" _agent_id="$2" _amb_path="$3"

    # (1) Fleet-hold check — exits 2 if cluster-detector wrote fleet-hold.txt
    #     (INFRA-1987 Phase 2). On hold: pivot to triage/docs work; don't ship.
    local _hold_active=0
    local _fleet_hold_check="${_repo_root}/scripts/coord/fleet-hold-check.sh"
    if [[ -x "$_fleet_hold_check" ]]; then
        if ! bash "$_fleet_hold_check" --quiet 2>/dev/null; then
            _hold_active=1
        fi
    fi
    export CHUMP_FLEET_HOLD_ACTIVE="$_hold_active"   # 0|1, cheap numeric compare for callers
    if [[ "$_hold_active" -eq 1 ]]; then
        export CHUMP_FLEET_HOLD="true"
    else
        export CHUMP_FLEET_HOLD="false"
    fi
    printf '{"ts":"%s","kind":"worker_floor_signal_read","agent_id":"%s","signal":"fleet_hold","hold":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_agent_id" "$_hold_active" \
        >> "$_amb_path" 2>/dev/null || true

    # (2) Floor-temperature check — exits 0=COLD, 1=WARM, 2=HOT (INFRA-1992).
    #     HOT: restrict to xs/docs gaps; WARM: double-verify; COLD: normal.
    local _floor_temp="COLD"
    if chump health --temp >/dev/null 2>&1; then
        _floor_temp="COLD"
    else
        local _temp_rc=$?
        case "$_temp_rc" in
            1) _floor_temp="WARM" ;;
            2) _floor_temp="HOT" ;;
            *) _floor_temp="COLD" ;;  # unknown / chump not available — proceed normally
        esac
    fi
    export CHUMP_FLOOR_TEMP="$_floor_temp"
    printf '{"ts":"%s","kind":"worker_floor_signal_read","agent_id":"%s","signal":"floor_temp","temp":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_agent_id" "$_floor_temp" \
        >> "$_amb_path" 2>/dev/null || true

    return 0
}
