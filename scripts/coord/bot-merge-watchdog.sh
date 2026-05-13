#!/usr/bin/env bash
# bot-merge-watchdog.sh — INFRA-1006
#
# Kills bot-merge.sh processes older than CHUMP_BOT_MERGE_MAX_AGE_S (default 1800s).
# Run every 5 min via launchd (see launchd/com.chump.bot-merge-watchdog.plist).
#
# Kill logic:
#   - Gap status=done OR PR merged/closed → SIGTERM (5s grace) + SIGKILL
#   - Gap still open but age-limited → emit warning, do NOT auto-kill (operator review)
#   - CHUMP_BOT_MERGE_NO_WATCHDOG=1 in the process env → skip that process
#
# Emits kind=bot_merge_watchdog_killed / bot_merge_watchdog_stuck to ambient.jsonl

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
MAX_AGE_S="${CHUMP_BOT_MERGE_MAX_AGE_S:-1800}"   # default 30 min (2× per-agent budget)
NOW_EPOCH=$(date +%s)

mkdir -p "$LOCK_DIR"

emit() {
    local kind="$1" payload="$2"
    printf '{"ts":"%s","kind":"%s",%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$payload" \
        >> "$AMBIENT_LOG"
}

killed=0
warned=0

# Find all bot-merge.sh PIDs. `pgrep -f` on macOS and Linux.
while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue

    # Calculate process age in seconds.
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: ps -p <pid> -o etime= returns [[DD-]HH:]MM:SS
        etime_raw=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || true)
        [[ -z "$etime_raw" ]] && continue
        age_s=$(python3 -c "
s = '$etime_raw'
parts = s.replace('-', ':').split(':')
parts = [int(x) for x in parts]
if len(parts) == 2:
    t = parts[0]*60 + parts[1]
elif len(parts) == 3:
    t = parts[0]*3600 + parts[1]*60 + parts[2]
elif len(parts) == 4:
    t = parts[0]*86400 + parts[1]*3600 + parts[2]*60 + parts[3]
else:
    t = 0
print(t)
" 2>/dev/null || echo 0)
    else
        # Linux: /proc/<pid>/stat field 22 is starttime in jiffies since boot
        btime=$(awk '/^btime/{print $2}' /proc/stat 2>/dev/null || echo 0)
        starttime=$(awk '{print $22}' /proc/"$pid"/stat 2>/dev/null || echo 0)
        hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
        age_s=$(python3 -c "print(int($NOW_EPOCH - $btime - $starttime / $hz))" 2>/dev/null || echo 0)
    fi

    [[ "$age_s" -lt "$MAX_AGE_S" ]] && continue

    # Respect per-process opt-out.
    proc_env=$(cat /proc/"$pid"/environ 2>/dev/null | tr '\0' '\n' | grep '^CHUMP_BOT_MERGE_NO_WATCHDOG=' || \
               ps eww -p "$pid" 2>/dev/null | grep -o 'CHUMP_BOT_MERGE_NO_WATCHDOG=[^ ]*' || true)
    if [[ "$proc_env" == *"CHUMP_BOT_MERGE_NO_WATCHDOG=1"* ]]; then
        continue
    fi

    # Extract gap ID from the command line (bot-merge.sh --gap INFRA-NNN).
    cmdline=$(ps -p "$pid" -o args= 2>/dev/null || cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ' || true)
    gap_id=$(echo "$cmdline" | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)

    gap_status="unknown"
    pr_status="unknown"
    if [[ -n "$gap_id" ]] && command -v chump &>/dev/null; then
        gap_status=$(chump gap show "$gap_id" --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "unknown")
        closed_pr=$(chump gap show "$gap_id" --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('closed_pr',''))" 2>/dev/null || echo "")
        if [[ -n "$closed_pr" && "$closed_pr" != "null" ]]; then
            pr_num="${closed_pr##*/}"
            pr_state=$(gh api "repos/repairman29/chump/pulls/$pr_num" --jq '.state' 2>/dev/null || echo "unknown")
            pr_status="$pr_state"
        fi
    fi

    should_kill=0
    if [[ "$gap_status" == "done" ]]; then
        should_kill=1
    elif [[ "$pr_status" == "closed" || "$pr_status" == "merged" ]]; then
        should_kill=1
    fi

    if [[ "$should_kill" -eq 1 ]]; then
        echo "[bot-merge-watchdog] killing PID $pid (gap=$gap_id age=${age_s}s status=$gap_status pr=$pr_status)"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 5
        kill -KILL "$pid" 2>/dev/null || true

        # Remove matching lease file.
        for lf in "$LOCK_DIR"/claim-*.json; do
            [ -f "$lf" ] || continue
            if grep -q "\"$pid\"" "$lf" 2>/dev/null; then
                rm -f "$lf"
                break
            fi
            # Also match by gap ID slug.
            _gap_lower=$(echo "$gap_id" | tr '[:upper:]' '[:lower:]')
            if [[ -n "$gap_id" ]] && echo "$lf" | grep -qi "$_gap_lower"; then
                rm -f "$lf"
                break
            fi
        done

        emit "bot_merge_watchdog_killed" \
            "\"pid\":$pid,\"gap\":\"$gap_id\",\"age_s\":$age_s,\"gap_status\":\"$gap_status\",\"pr_status\":\"$pr_status\""
        killed=$((killed + 1))
    else
        echo "[bot-merge-watchdog] WARN: PID $pid (gap=$gap_id age=${age_s}s) over limit but gap open — operator review needed"
        emit "bot_merge_watchdog_stuck" \
            "\"pid\":$pid,\"gap\":\"$gap_id\",\"age_s\":$age_s,\"gap_status\":\"$gap_status\",\"pr_status\":\"$pr_status\""
        warned=$((warned + 1))
    fi
done < <(pgrep -f 'bot-merge.sh' 2>/dev/null || true)

echo "[bot-merge-watchdog] done: killed=$killed warned=$warned (max_age=${MAX_AGE_S}s)"
