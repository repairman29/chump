#!/usr/bin/env bash
# ChumpBar per-node pause/resume control (EFFECTIVE-309).
#
# Sets the RESILIENT-073 kill switch (~/.chump/AUTONOMY_LEVEL) on one node so the
# operator can pause/resume any fleet node straight from the menu bar. This is
# the AUTHORITATIVE pause: every work entry-point (chump claim) fail-closes when
# AUTONOMY_LEVEL is 0/missing, so a paused node cannot autoship.
#
#   pause  = level 0  (fleet stopped; on `local` also kills tmux workers)
#   resume = level 5  (fleet armed; does NOT auto-launch a full fleet — that is
#                      a separate deliberate `chump fleet start`)
#
# Usage: chumpbar-pause.sh <node> <pause|resume|0|5>
#   node: local | helsinki | closetjunky   (remotes use the ssh alias)
#
# Remote nodes are reached via their ssh alias (~/.ssh/config), matching how
# chumpbar-status.sh already talks to them. An unreachable node reports the
# failure and exits non-zero so the menu can surface it.
set -euo pipefail

node="${1:?usage: chumpbar-pause.sh <node> <pause|resume|0|5>}"
action="${2:?usage: chumpbar-pause.sh <node> <pause|resume|0|5>}"

case "$action" in
    pause|0|stop) level=0 ;;
    resume|5|start|go) level=5 ;;
    1) level=1 ;;
    *) echo "chumpbar-pause: action must be pause|resume (or 0|5), got '$action'" >&2; exit 2 ;;
esac

CHUMP_BIN="${CHUMP_BIN:-/opt/homebrew/bin/chump}"

if [[ "$node" == "local" ]]; then
    if [[ "$level" == "0" ]]; then
        # Authoritative stop: level 0 + kill any local tmux workers.
        if [[ -x "$CHUMP_BIN" ]]; then
            "$CHUMP_BIN" fleet stop >/dev/null 2>&1 || true
        fi
        mkdir -p "$HOME/.chump"; echo 0 > "$HOME/.chump/AUTONOMY_LEVEL"
    else
        mkdir -p "$HOME/.chump"; echo "$level" > "$HOME/.chump/AUTONOMY_LEVEL"
    fi
    echo "local → AUTONOMY_LEVEL=$level"
    exit 0
fi

# Remote node: write the level over ssh (idempotent, no daemon needed).
if ssh -o BatchMode=yes -o ConnectTimeout="${CHUMPBAR_SSH_TIMEOUT:-15}" "$node" \
       "mkdir -p ~/.chump && printf '%s\n' '$level' > ~/.chump/AUTONOMY_LEVEL" 2>/dev/null; then
    echo "$node → AUTONOMY_LEVEL=$level"
else
    echo "chumpbar-pause: FAILED to reach $node (ssh)" >&2
    exit 1
fi
