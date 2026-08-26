#!/usr/bin/env bash
# svc-abstraction.sh — INFRA-3723 (INFRA-3649 slice, MISSION-010).
#
# WHY THIS EXISTS. scripts/ops/process-organ-heal.sh already knows how to
# pgrep-check and nohup-respawn a registered process-organ, but that logic
# is inlined in the heal loop's while-read — nothing else in the fleet can
# reuse "is this organ alive" / "revive this organ" without copy-pasting the
# same pgrep/nohup incantation. This is that reusable abstraction: two
# functions, sourceable from any script, over the SAME on-disk organ shape
# (~/.chump/organs/<name>.sh, matching install-node-housekeeping.sh's
# $STATE/organs/$name.sh layout) so every future svc consumer (INFRA-3649's
# other slices) shares one liveness/revival primitive instead of reinventing
# pgrep patterns per-script.
#
# This is a LIBRARY, not an entrypoint — source it, don't execute it:
#   source scripts/ops/svc-abstraction.sh
#   svc_is_alive almanac-vision-keeper || svc_revive almanac-vision-keeper
#
# Functions:
#   svc_is_alive <organ_name>
#     pgrep -f match against "organs/${organ_name}.sh" (relative match, so it
#     hits regardless of which $HOME the organ was installed under).
#     Returns 0 if a matching process is running, 1 if not.
#
#   svc_revive <organ_name>
#     Launches ~/.chump/organs/<organ_name>.sh detached (setsid, falling back
#     to nohup+disown if setsid is unavailable), stdout/stderr appended to
#     ~/.chump/logs/organ_<organ_name>.log. Returns 0 once launched, 1 if the
#     organ script doesn't exist on disk.
#
# Env:
#   CHUMP_SVC_ORGANS_DIR   — override organs dir (default ~/.chump/organs)
#   CHUMP_SVC_LOGS_DIR     — override logs dir (default ~/.chump/logs)
#   CHUMP_SVC_PGREP_BIN    — override `pgrep` binary (test hook)
set -uo pipefail

CHUMP_SVC_ORGANS_DIR="${CHUMP_SVC_ORGANS_DIR:-$HOME/.chump/organs}"
CHUMP_SVC_LOGS_DIR="${CHUMP_SVC_LOGS_DIR:-$HOME/.chump/logs}"
CHUMP_SVC_PGREP_BIN="${CHUMP_SVC_PGREP_BIN:-pgrep}"

svc_is_alive() {
    local organ_name="$1"
    if ! command -v "$CHUMP_SVC_PGREP_BIN" >/dev/null 2>&1; then
        echo "[svc-abstraction] WARN: $CHUMP_SVC_PGREP_BIN unavailable — cannot check liveness for $organ_name" >&2
        return 1
    fi
    "$CHUMP_SVC_PGREP_BIN" -f "organs/${organ_name}.sh" >/dev/null 2>&1
}

svc_revive() {
    local organ_name="$1"
    local organ_path="$CHUMP_SVC_ORGANS_DIR/${organ_name}.sh"

    if [[ ! -f "$organ_path" ]]; then
        echo "[svc-abstraction] ERROR: organ script not found at $organ_path — cannot revive $organ_name" >&2
        return 1
    fi

    mkdir -p "$CHUMP_SVC_LOGS_DIR" 2>/dev/null || true
    local log_file="$CHUMP_SVC_LOGS_DIR/organ_${organ_name}.log"

    if command -v setsid >/dev/null 2>&1; then
        setsid bash "$organ_path" >>"$log_file" 2>&1 < /dev/null &
    else
        nohup bash "$organ_path" >>"$log_file" 2>&1 < /dev/null &
        disown 2>/dev/null || true
    fi
    echo "[svc-abstraction] revived $organ_name (pid $!, log $log_file)"
    return 0
}
