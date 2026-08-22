#!/usr/bin/env bash
# almanac-vision-keeper.sh — the "eyes" as a standing process (INFRA-3650,
# PEER-HEAL-03, MISSION-010).
#
# almanac-liveness-refresh.sh (INFRA-3643/TREK-17) is a single-pass
# check-and-fix; on a systemd node it gets a cadence from
# chump-almanac-liveness.timer (install-almanac-organ.sh, INFRA-3657). This
# script is the OTHER way that cadence gets applied: a plain infinite loop,
# for hosts/paths where the "eyes" run as a raw background bash process
# instead of a supervised systemd unit. That's exactly the shape
# process-organ-heal.sh (INFRA-3650) exists to watch — pgrep -f on this
# script's own path is a reliable, host-independent liveness signal, and if
# this loop dies (unsupervised bash procs don't self-restart) the heal loop
# respawns it from scripts/ops/process-organ-registry.txt.
#
# Usage:
#   scripts/ops/almanac-vision-keeper.sh          # loop forever
#   scripts/ops/almanac-vision-keeper.sh --once   # single pass, for tests
#
# Env:
#   CHUMP_VISION_KEEPER_INTERVAL_S — seconds between passes (default 900 = 15min,
#                                    matches chump-almanac-liveness.timer's cadence)
#   REPO_ROOT / CHUMP_REPO_ROOT    — repo checkout to find the liveness script in
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
LIVENESS_SCRIPT="$REPO_ROOT/scripts/ops/almanac-liveness-refresh.sh"
INTERVAL="${CHUMP_VISION_KEEPER_INTERVAL_S:-900}"

ONCE=0
[[ "${1:-}" == "--once" ]] && ONCE=1

while true; do
    if [[ -x "$LIVENESS_SCRIPT" ]]; then
        "$LIVENESS_SCRIPT" || echo "[almanac-vision-keeper] liveness-refresh exited non-zero (non-fatal, retrying next cycle)" >&2
    else
        echo "[almanac-vision-keeper] WARN: liveness script missing/not executable: $LIVENESS_SCRIPT" >&2
    fi
    [[ "$ONCE" == "1" ]] && break
    sleep "$INTERVAL"
done
