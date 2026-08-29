#!/usr/bin/env bash
# stale-bot-merge-reaper.sh — INFRA-673, engine-ified INFRA-1572
#
# Kills bash processes matching 'bot-merge.sh' that have been running longer
# than 1 hour.  38 zombies (1-4 days old) wedged the entire fleet on 2026-05-08,
# blocking child claude -p workers and starving the queue.
#
# Consumes the generic scripts/lib/reaper.sh engine — this script only
# supplies the find command (ps -> pid/age) and reuses the engine's
# kill action. See docs/audits/reaper-curation-2026-05.md for why this
# reaper (and not its 10 siblings) was picked for engine consolidation.
#
# Usage:
#   ./scripts/ops/stale-bot-merge-reaper.sh              # dry-run (default)
#   ./scripts/ops/stale-bot-merge-reaper.sh --dry-run    # explicit dry-run
#   ./scripts/ops/stale-bot-merge-reaper.sh --execute    # actually kill
#
# LaunchAgent: dev.chump.stale-bot-merge-reaper (every 30 min)
#   Install: load scripts/plists/dev.chump.stale-bot-merge-reaper.plist

set -uo pipefail

# shellcheck source=../lib/reaper.sh
source "$(dirname "$0")/../lib/reaper.sh"

# etime from ps is in [[DD-]HH:]MM:SS format; convert to seconds.
_stale_bot_merge_etime_to_seconds() {
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
export -f _stale_bot_merge_etime_to_seconds

REAPER_NAME=stale_bot_merge
REAPER_AGE_THRESHOLD_S=3600
REAPER_FIND_CMD='ps -eo pid=,etime=,args= 2>/dev/null | grep "bot-merge\.sh" | grep -v grep | while IFS= read -r line; do
    pid="$(echo "$line" | awk "{print \$1}")"
    etime="$(echo "$line" | awk "{print \$2}")"
    age="$(_stale_bot_merge_etime_to_seconds "$etime")"
    printf "%s\t%s\t%s\n" "$pid" "$age" "$etime"
done'
REAPER_ACTION_CMD='reaper_engine_kill'

reaper_engine_run "$@"
