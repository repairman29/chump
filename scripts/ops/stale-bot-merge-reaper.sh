#!/usr/bin/env bash
# stale-bot-merge-reaper.sh — INFRA-673
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

DRY_RUN=true
for arg in "$@"; do
    case "$arg" in
        --execute) DRY_RUN=false ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
THRESHOLD_SECONDS=3600  # 1 hour

# etime from ps is in [[DD-]HH:]MM:SS format; convert to seconds.
etime_to_seconds() {
    local etime="$1"
    local days=0 hours=0 mins=0 secs=0

    # Strip leading whitespace
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

KILLED=()
SKIPPED=0

# Collect PIDs + etime for all bash processes with bot-merge.sh in their args.
# Use -o to get pid, etime, and command without truncation.
while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    pid="$(echo "$line" | awk '{print $1}')"
    etime="$(echo "$line" | awk '{print $2}')"
    elapsed=$(etime_to_seconds "$etime")

    if (( elapsed < THRESHOLD_SECONDS )); then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  WOULD KILL pid=$pid etime=$etime elapsed=${elapsed}s"
    else
        echo "  KILLING pid=$pid etime=$etime elapsed=${elapsed}s"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$pid" 2>/dev/null || true
        KILLED+=("$pid")
    fi
done < <(ps -eo pid=,etime=,args= 2>/dev/null | grep 'bot-merge\.sh' | grep -v grep || true)

echo
echo "stale-bot-merge-reaper: killed=${#KILLED[@]} skipped=$SKIPPED dry_run=$DRY_RUN"

if [[ "$DRY_RUN" == "false" && "${#KILLED[@]}" -gt 0 ]]; then
    pid_list="$(IFS=,; echo "${KILLED[*]}")"
    printf '{"ts":"%s","kind":"stale_bot_merge_killed","pids":[%s],"count":%d}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(IFS=,; echo "${KILLED[*]}" | sed 's/,/, /g')" \
        "${#KILLED[@]}" \
        >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
    echo "  -> emitted stale_bot_merge_killed to ambient.jsonl (pids=$pid_list)"
fi
