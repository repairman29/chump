#!/usr/bin/env bash
# discord-gateway-liveness.sh — RESILIENT-266.
#
# Alarm when the Discord gateway is not running.
#
# WHY THIS EXISTS, and why it is not optional. ~/.chump/operator-recall.toml has
# said `enabled = true` since 2026-05-08 with ZERO processes running, against a
# stale pidfile. Nobody noticed for three months, because nothing checked. A
# notifier that dies silently is worse than no notifier: it manufactures
# confidence that somebody would have been told. PR #3510 was destroyed while
# that channel was "enabled".
#
# THE LOAD-BEARING DESIGN CHOICE: the alarm must not travel through the thing
# being checked. This uses scripts/coord/lib/notify-operator.sh, which is plain
# Discord REST (src/discord_dm.rs's path) and needs NO gateway bot. So a dead
# gateway can still report itself dead. If this ever gets "simplified" to route
# through the gateway, it becomes a check that goes quiet exactly when it
# matters — which is the bug it exists to prevent.
#
# Usage:
#   bash scripts/coord/discord-gateway-liveness.sh          # check + alarm
#   bash scripts/coord/discord-gateway-liveness.sh --quiet  # exit code only
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

# shellcheck source=lib/notify-operator.sh
if [[ -f "$SCRIPT_DIR/lib/notify-operator.sh" ]]; then
    source "$SCRIPT_DIR/lib/notify-operator.sh"
else
    notify_operator() { echo "[liveness] notify-operator.sh MISSING" >&2; return 1; }
fi

STATE_DIR="${HOME}/.chump"
LAST_ALARM="${STATE_DIR}/discord-gateway-last-alarm"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Count real gateway processes. NOTE: macOS BSD pgrep has no -c, and piping to
# `|| echo 0` turns an error into a FALSE ZERO — a mistake that caused two
# misdiagnoses in one session. Count with wc -l and never trust a bare pgrep -c.
running="$(pgrep -f 'chump.*--discord|chump-discord-gateway' 2>/dev/null | wc -l | tr -d ' ')"
running="${running:-0}"

if (( running > 0 )); then
    [[ $QUIET -eq 1 ]] || echo "[liveness] OK — discord gateway running (${running} process(es))"
    rm -f "$LAST_ALARM" 2>/dev/null || true
    exit 0
fi

[[ $QUIET -eq 1 ]] || echo "[liveness] DOWN — no discord gateway process found" >&2

# Rate-limit: alarm at most once every 6h so a long outage does not become a
# stream of identical DMs. A channel that cries wolf gets muted, and a muted
# channel is the dead operator-recall handler all over again.
now="$(date -u +%s)"
if [[ -f "$LAST_ALARM" ]]; then
    last="$(cat "$LAST_ALARM" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last < 21600 )); then
        [[ $QUIET -eq 1 ]] || echo "[liveness] alarm suppressed (last was $(( (now - last) / 60 ))m ago)" >&2
        exit 1
    fi
fi

notify_operator "$(printf '📵 **Chump Discord gateway is DOWN.**\n\nNo gateway process is running, so **replies and button taps are going nowhere right now.** Outbound alerts (like this one) still work — they use REST and need no bot.\n\nRestart:\n```\nlaunchctl kickstart -k gui/$(id -u)/ai.chump.discord-gateway\n```\n\nThis check exists because `operator-recall` sat `enabled = true` with zero processes from 2026-05-08 and nothing noticed for three months. Rate-limited to once per 6h.')" \
    && echo "$now" > "$LAST_ALARM" 2>/dev/null || true

exit 1
