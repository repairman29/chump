#!/usr/bin/env bash
# fleet-autorestart-daemon.sh — INFRA-611: auto-restart daemon for the fleet.
#
# Watches ambient.jsonl for trigger conditions and restarts the fleet
# automatically. Spawned by run-fleet.sh outside tmux, alongside the
# orphan-reaper sentinel (INFRA-602). Exits when the fleet tmux session
# disappears.
#
# INFRA-623 trigger: fleet_auth_storm
#   When CHUMP_AUTH_STORM_RESTART_THRESHOLD (default 3) fleet_auth_storm
#   events appear in ambient.jsonl, calls:
#     fleet-restart.sh --refresh-auth --fleet-start-epoch $FLEET_START_EPOCH
#   which re-probes credentials before relaunching the fleet (3-path logic).
#
# Env knobs:
#   CHUMP_AUTH_STORM_RESTART_THRESHOLD  (default 3)  fleet_auth_storm events
#                                       needed to trigger a restart.
#   FLEET_SESSION                       (default chump-fleet)
#   FLEET_START_EPOCH                   Unix epoch from run-fleet.sh launch.
#   CHUMP_AMBIENT_LOG                   path to ambient.jsonl.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
FLEET_SESSION="${FLEET_SESSION:-chump-fleet}"
FLEET_START_EPOCH="${FLEET_START_EPOCH:-0}"
_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
_restart_script="$REPO_ROOT/scripts/dispatch/fleet-restart.sh"

_auth_storm_count=0
_auth_storm_restart_threshold="${CHUMP_AUTH_STORM_RESTART_THRESHOLD:-3}"

_log() { printf '[fleet-autorestart-daemon] %s\n' "$*"; }
_fleet_alive() { tmux has-session -t "$FLEET_SESSION" 2>/dev/null; }

# Brief wait for ambient.jsonl to be created by the first worker cycle
_waited=0
while [[ ! -f "$_amb" ]] && _fleet_alive; do
    sleep 2
    (( _waited += 2 )) || true
    [[ $_waited -ge 60 ]] && break
done

_log "started — session=$FLEET_SESSION threshold=$_auth_storm_restart_threshold amb=$_amb"

# Process new lines from ambient.jsonl; exit when the fleet session is gone.
# tail -F handles log rotation and files that don't exist yet.
tail -F "$_amb" 2>/dev/null | while IFS= read -r _line; do
    # Bail out when the fleet session has gone away
    if ! _fleet_alive; then
        _log "fleet session '$FLEET_SESSION' gone — exiting"
        break
    fi

    # ── fleet_auth_storm trigger (INFRA-623) ───────────────────────────────
    if printf '%s' "$_line" | grep -q '"kind":"fleet_auth_storm"'; then
        (( _auth_storm_count += 1 )) || true
        _log "fleet_auth_storm event #${_auth_storm_count}/${_auth_storm_restart_threshold}"

        if [[ "$_auth_storm_count" -ge "$_auth_storm_restart_threshold" ]]; then
            _log "auth-storm threshold reached — triggering fleet restart with credential refresh"
            _auth_storm_count=0   # reset before fork so re-trigger doesn't loop

            # Run restart in background; if it exits 4 (unrecoverable) the fleet
            # stays halted and the operator-actionable message is in the log.
            FLEET_SESSION="$FLEET_SESSION" \
            FLEET_START_EPOCH="$FLEET_START_EPOCH" \
            CHUMP_AMBIENT_LOG="$_amb" \
            REPO_ROOT="$REPO_ROOT" \
            "$_restart_script" --refresh-auth --fleet-start-epoch "$FLEET_START_EPOCH" &
        fi
    fi
done
