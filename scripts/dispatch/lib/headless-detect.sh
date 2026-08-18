#!/usr/bin/env bash
# headless-detect.sh — RESILIENT-283: decide whether run-fleet.sh should spawn
# control.sh (the interactive curses dashboard, pane 0) or run headless.
#
# control.sh calls `clear`, which requires a real TERM. On a fresh headless
# Linux node (systemd/ssh session with TERM unset, or TERM=dumb) that call
# fails immediately, control.sh exits rc=1, and since it was launched as the
# tmux session's pane-0 command, the whole session dies before the
# `tmux split-window` calls that spawn worker panes ever run — zero workers
# spawn even though `chump fleet up` reports success.
#
# fleet_headless_mode <FLEET_HEADLESS> <TERM> prints "1" (headless: skip the
# dashboard, run a worker in pane 0 instead) or "0" (interactive: dashboard
# as normal). FLEET_HEADLESS may be "auto" (the default — decide from TERM),
# or an explicit "0"/"1" operator override.
fleet_headless_mode() {
    local requested="${1:-auto}"
    local term="${2:-}"
    case "$requested" in
        0|1)
            printf '%s\n' "$requested"
            return 0
            ;;
    esac
    if [[ -z "$term" || "$term" == "dumb" ]]; then
        printf '1\n'
    else
        printf '0\n'
    fi
}

# Allow sourcing without side effects when run directly for a quick check:
#   bash scripts/dispatch/lib/headless-detect.sh
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    fleet_headless_mode "${FLEET_HEADLESS:-auto}" "${TERM:-}"
fi
