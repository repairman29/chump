#!/usr/bin/env bash
# stale-bot-merge-reaper.sh — INFRA-673, ported to scripts/lib/reaper.sh INFRA-1572
#
# Kills bash processes matching 'bot-merge.sh' that have been running longer
# than 1 hour.  38 zombies (1-4 days old) wedged the entire fleet on 2026-05-08,
# blocking child claude -p workers and starving the queue.
#
# Usage:
#   ./scripts/ops/stale-bot-merge-reaper.sh              # dry-run (default)
#   ./scripts/ops/stale-bot-merge-reaper.sh --dry-run    # explicit dry-run
#   ./scripts/ops/stale-bot-merge-reaper.sh --execute    # actually kill
#
# LaunchAgent: dev.chump.stale-bot-merge-reaper (every 30 min)
#   Install: load scripts/plists/dev.chump.stale-bot-merge-reaper.plist

set -euo pipefail

REAPER_DRY_RUN=true
for arg in "$@"; do
    case "$arg" in
        --execute) REAPER_DRY_RUN=false ;;
        --dry-run) REAPER_DRY_RUN=true ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")"
REAPER_LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
THRESHOLD_SECONDS="${CHUMP_STALE_BOT_MERGE_AGE_S:-3600}"  # 1 hour

# shellcheck source=../lib/reaper.sh
source "$REPO_ROOT/scripts/lib/reaper.sh"

# etime from ps is in [[DD-]HH:]MM:SS format; convert to seconds.
etime_to_seconds() {
    local etime="$1"
    local days=0 hours=0 mins=0 secs=0

    etime="${etime# }"

    if [[ "$etime" == *-* ]]; then
        days="${etime%%-*}"
        etime="${etime#*-}"
    fi

    IFS=: read -r -a parts <<< "$etime"
    case "${#parts[@]}" in
        3) hours="${parts[0]}"; mins="${parts[1]}"; secs="${parts[2]}" ;;
        2) mins="${parts[0]}"; secs="${parts[1]}" ;;
        1) secs="${parts[0]}" ;;
    esac

    echo $(( days * 86400 + hours * 3600 + mins * 60 + secs ))
}

# candidate = "pid etime" (space-separated, one bot-merge.sh process per line)
_stale_bot_merge_find() {
    ps -eo pid=,etime=,args= 2>/dev/null | grep 'bot-merge\.sh' | grep -v grep \
        | awk '{print $1, $2}' || true
}

REAPER_NAME="stale-bot-merge-reaper"
REAPER_FIND_CMD='_stale_bot_merge_find'
REAPER_PREDICATE_CMD='
    pid="${candidate%% *}"; etime="${candidate#* }"
    elapsed=$(etime_to_seconds "$etime")
    (( elapsed >= THRESHOLD_SECONDS ))
'
REAPER_ACTION_CMD='
    pid="${candidate%% *}"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
'
REAPER_AMBIENT_KIND="stale_bot_merge_killed"

reaper_engine_run
