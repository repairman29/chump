#!/usr/bin/env bash
# agent-loop.sh — run a Claude Code gap-worker in a continuous shell loop.
#
# Use this when you can't do /loop interactively (CI, cron, background terminal).
# The agent does one gap per invocation and exits. This script retries until
# the queue is empty or --max-gaps is reached.
#
# Usage:
#   scripts/agent-loop.sh                   # loop forever
#   scripts/agent-loop.sh --max-gaps 5      # stop after 5 gaps
#   scripts/agent-loop.sh --interval 90     # seconds between runs (default: 60)

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

MAX_GAPS=0        # 0 = unlimited
INTERVAL=60       # seconds between runs
GAPS_DONE=0
EMPTY_STREAK=0
MAX_EMPTY=5       # give up after 5 consecutive empty-queue runs

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-gaps)  MAX_GAPS="$2";  shift 2 ;;
        --interval)  INTERVAL="$2"; shift 2 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

AGENT_PROMPT="You are a Chump agent on the autonomous work queue. \
Read docs/architecture/AGENT_LOOP.md and follow the loop instructions exactly. \
Pick ONE gap, do the work, ship it via scripts/bot-merge.sh --gap <ID> --auto-merge, \
then exit. Do not call ScheduleWakeup — the shell loop handles retries."

check_queue() {
    python3.12 scripts/musher.py --pick >/dev/null 2>&1
}

echo "[agent-loop] Starting. max_gaps=${MAX_GAPS:-unlimited} interval=${INTERVAL}s"

while true; do
    if [[ "$MAX_GAPS" -gt 0 && "$GAPS_DONE" -ge "$MAX_GAPS" ]]; then
        echo "[agent-loop] Reached max-gaps=$MAX_GAPS. Exiting."
        exit 0
    fi

    echo "[agent-loop] Fetching main..."
    git fetch origin main --quiet 2>/dev/null || true

    if ! check_queue; then
        EMPTY_STREAK=$(( EMPTY_STREAK + 1 ))
        echo "[agent-loop] Queue empty (streak $EMPTY_STREAK/$MAX_EMPTY). Sleeping ${INTERVAL}s..."
        if [[ "$EMPTY_STREAK" -ge "$MAX_EMPTY" ]]; then
            echo "[agent-loop] Queue empty for $MAX_EMPTY consecutive checks. Exiting."
            exit 0
        fi
        sleep "$INTERVAL"
        continue
    fi

    EMPTY_STREAK=0
    echo "[agent-loop] Gap available — invoking agent (run $((GAPS_DONE + 1)))..."
    claude -p "$AGENT_PROMPT" --dangerously-skip-permissions 2>&1 || true
    GAPS_DONE=$(( GAPS_DONE + 1 ))
    echo "[agent-loop] Run $GAPS_DONE complete. Sleeping ${INTERVAL}s..."
    sleep "$INTERVAL"
done
