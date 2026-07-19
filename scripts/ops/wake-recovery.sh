#!/usr/bin/env bash
# wake-recovery.sh — RESILIENT-169: turn system sleep from DEATH into a PAUSE.
#
# Invoked by the chumpwake daemon (tools/chumpwake) on every system wake.
# The June 22→28 six-day outage was a lid-close: all fleet processes suspended,
# oauth refresh stopped, and on each brief DarkWake the stale auth-status cache
# (CREDIBLE-147) blocked self-heal. This routine makes reopening the lid restore
# service within one farmer TTL window (~1-5 min):
#
#   1. bust the auth-status cache (the CREDIBLE-147 poison)
#   2. re-probe auth for real (validity, not presence)
#   3. kick the farmer so dead workers get revived NOW, not next interval
#   4. emit kind=wake_recovery to ambient.jsonl so the resume is auditable
#
# Rust-First-Bypass: launchctl/rm/date glue around existing tools; ambient
# append is the shared fleet emit pattern (broadcast.sh precedent).

set -uo pipefail

REPO="${CHUMP_REPO:-$HOME/Projects/Chump}"
AMBIENT="${REPO}/.chump-locks/ambient.jsonl"
UID_N="$(id -u)"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 1. Bust the stale auth cache — harmless if absent.
rm -f "$HOME/.chump/auth-status-cache" 2>/dev/null || true

# 2. Fresh validity probe (never trust the pre-sleep answer).
auth_rc=1
auth_line=""
if [[ -x "$REPO/scripts/coord/auth-status.sh" ]]; then
    auth_line="$(bash "$REPO/scripts/coord/auth-status.sh" 2>&1 | tail -1 || true)"
    case "$auth_line" in *"OK"*) auth_rc=0 ;; esac
fi

# 3. Kick the revival chain: farmer first (revives workers), then the
#    merge path (integrator + monitor) so a drained queue restarts too.
kicked=""
for svc in dev.chump.farmer-brown com.chump.integrator-daemon com.chump.merge-queue-monitor; do
    if launchctl kickstart "gui/${UID_N}/${svc}" 2>/dev/null; then
        kicked="${kicked}${svc},"
    fi
done
kicked="${kicked%,}"

# 4. Auditable trail.
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
printf '{"ts":"%s","kind":"wake_recovery","auth_ok":%s,"kicked":"%s","note":"system wake — cache busted, auth re-probed, revival chain kicked"}\n' \
    "$(ts)" "$([[ $auth_rc -eq 0 ]] && echo true || echo false)" "$kicked" \
    >> "$AMBIENT" 2>/dev/null || true

echo "[wake-recovery] $(ts) auth_ok=$([[ $auth_rc -eq 0 ]] && echo true || echo false) kicked=$kicked"
