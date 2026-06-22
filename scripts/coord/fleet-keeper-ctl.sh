#!/usr/bin/env bash
# fleet-keeper-ctl.sh — RESILIENT-158 operator control + health surface for the
# durable worker-pool keeper (the ensure_worker_pool step in fleet-autopilot.sh,
# which runs every ~5min under launchd and relaunches run-fleet if it's down).
#
#   fleet-keeper-ctl.sh status   health: keeper on/off, fleet up/down, worker count, last ship
#   fleet-keeper-ctl.sh stop     KILL the running fleet NOW + disable auto-relaunch (persists)
#   fleet-keeper-ctl.sh start    re-enable auto-relaunch (keeper relaunches within ~5min)
#   fleet-keeper-ctl.sh kill     kill the running fleet NOW only (keeper WILL relaunch next tick)
#
# "stop" is the big red button: it both kills the live pool AND sets the flag so
# the keeper won't bring it back. "start" undoes it. "kill" is a soft bounce
# (useful to force a fresh relaunch on current scripts).
set -uo pipefail

OFF_FLAG="$HOME/.chump/FLEET_KEEPER_OFF"
SESSION="chump-fleet"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_live_panes() {
    tmux has-session -t "$SESSION" 2>/dev/null || { echo 0; return; }
    tmux list-panes -t "$SESSION" -F '#{pane_dead}' 2>/dev/null | grep -c '^0$' || echo 0
}

cmd_status() {
    local keeper="ENABLED (auto-relaunch ON)"
    [[ -f "$OFF_FLAG" ]] && keeper="DISABLED (flag: $OFF_FLAG)"
    [[ "${CHUMP_FLEET_KEEPER_DISABLE:-0}" == "1" ]] && keeper="DISABLED (env CHUMP_FLEET_KEEPER_DISABLE=1)"
    local panes; panes="$(_live_panes)"
    local fleet="DOWN"
    [[ "$panes" -gt 0 ]] && fleet="UP ($panes live panes; ~$((panes-1)) workers)"
    echo "── fleet keeper status ──────────────────────────────────"
    echo "  keeper          : $keeper"
    echo "  worker pool     : $fleet"
    echo "  autopilot daemon: $(launchctl list 2>/dev/null | grep -q com.chump.fleet-autopilot && echo 'loaded (heartbeat owner)' || echo 'NOT loaded — keeper will not run!')"
    echo "  last ship       : $(cd "$REPO_ROOT" && git log origin/main -1 --pretty='%cr — %s' 2>/dev/null || echo unknown)"
    echo "  last keeper act : $(grep 'RESILIENT-158 worker-pool keeper' "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null | tail -1 | grep -oE '"ts":"[^"]+"' || echo none)"
    echo "  attach          : tmux attach -t $SESSION    (detach: Ctrl-b d)"
    echo "──────────────────────────────────────────────────────────"
}

case "${1:-status}" in
    status) cmd_status ;;
    stop)
        touch "$OFF_FLAG"
        tmux kill-session -t "$SESSION" 2>/dev/null && echo "killed running fleet" || echo "(no running fleet)"
        echo "STOPPED: auto-relaunch DISABLED via $OFF_FLAG — fleet will stay down."
        echo "Resume with: $0 start"
        ;;
    start)
        rm -f "$OFF_FLAG"
        echo "STARTED: auto-relaunch ENABLED — the fleet-autopilot heartbeat will relaunch the pool within ~5min."
        echo "(launch now instead of waiting: launchctl kickstart -k gui/\$(id -u)/com.chump.fleet-autopilot)"
        ;;
    kill)
        tmux kill-session -t "$SESSION" 2>/dev/null && echo "killed running fleet" || echo "(no running fleet)"
        echo "NOTE: keeper is still enabled — it will relaunch within ~5min. Use 'stop' to keep it down."
        ;;
    *) echo "usage: $0 {status|stop|start|kill}" >&2; exit 2 ;;
esac
