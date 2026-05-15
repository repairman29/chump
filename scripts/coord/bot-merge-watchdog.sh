#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: lib/ dynamic; SC2034: SCRIPT_DIR kept for future use
# bot-merge-watchdog.sh — INFRA-1006 + INFRA-1315
#
# Kills bot-merge.sh processes whose gap is already done OR that have been
# running longer than CHUMP_BOT_MERGE_MAX_AGE_S (default 1800s).
# Run every 5 min via launchd (see launchd/com.chump.bot-merge-watchdog.plist).
#
# Kill logic (INFRA-1315: gap-done check runs BEFORE the age gate):
#   - Gap status=done OR PR merged/closed → SIGTERM (5s grace) + SIGKILL immediately
#     regardless of process age (previously required age > MAX_AGE_S first, causing
#     up to 30-min zombie accumulation after a gap shipped)
#   - Gap still open but age-limited → emit warning, do NOT auto-kill (operator review)
#   - CHUMP_BOT_MERGE_NO_WATCHDOG=1 in the process env → skip that process
#
# Sources (INFRA-1315):
#   1. .chump-locks/bot-merge-*.health files — read gap_ids field directly
#   2. pgrep -f 'bot-merge.sh' — fallback process scan for pre-health-write zombies
#
# Usage:
#   scripts/coord/bot-merge-watchdog.sh             # execute (default — safe, kills only zombies)
#   scripts/coord/bot-merge-watchdog.sh --dry-run   # report only, no kills
#
# Emits kind=bot_merge_watchdog_killed / bot_merge_watchdog_stuck to ambient.jsonl
#
# Environment:
#   CHUMP_LOCK_DIR  — override .chump-locks path
#   CHUMP_BIN       — override chump binary path (default: chump) — useful for tests

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
MAX_AGE_S="${CHUMP_BOT_MERGE_MAX_AGE_S:-1800}"   # default 30 min (2× per-agent budget)
NOW_EPOCH=$(date +%s)
CHUMP_CMD="${CHUMP_BIN:-chump}"
DRY_RUN=0

# Parse args.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --lock-dir) LOCK_DIR="$2"; AMBIENT_LOG="$LOCK_DIR/ambient.jsonl"; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[bot-merge-watchdog] unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$LOCK_DIR"

emit() {
    local kind="$1" payload="$2"
    printf '{"ts":"%s","kind":"%s",%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$payload" \
        >> "$AMBIENT_LOG"
}

killed=0
warned=0
# Track PIDs already handled (de-dup between health-file scan and ps scan).
declare -a _handled_pids=()

# ── Helper: check process age in seconds ─────────────────────────────────────
_process_age_s() {
    local pid="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        local etime_raw
        etime_raw=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ' || true)
        [[ -z "$etime_raw" ]] && echo 0 && return
        python3 -c "
s = '$etime_raw'
parts = s.replace('-', ':').split(':')
parts = [int(x) for x in parts]
if len(parts) == 2:   t = parts[0]*60 + parts[1]
elif len(parts) == 3: t = parts[0]*3600 + parts[1]*60 + parts[2]
elif len(parts) == 4: t = parts[0]*86400 + parts[1]*3600 + parts[2]*60 + parts[3]
else:                 t = 0
print(t)
" 2>/dev/null || echo 0
    else
        local btime starttime hz
        btime=$(awk '/^btime/{print $2}' /proc/stat 2>/dev/null || echo 0)
        starttime=$(awk '{print $22}' /proc/"$pid"/stat 2>/dev/null || echo 0)
        hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
        python3 -c "print(int($NOW_EPOCH - $btime - $starttime / $hz))" 2>/dev/null || echo 0
    fi
}

# ── Helper: resolve gap status ───────────────────────────────────────────────
_gap_status() {
    local gid="$1"
    [[ -z "$gid" ]] && echo "unknown" && return
    "$CHUMP_CMD" gap show "$gid" 2>/dev/null \
        | grep -E '^\s*status:' | awk '{print $2}' || echo "unknown"
}

# ── Helper: kill a process with SIGTERM + grace + SIGKILL ────────────────────
_kill_process() {
    local pid="$1" gap_id="$2" age_s="$3" gap_status="$4" pr_status="${5:-}"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[bot-merge-watchdog] DRY-RUN: would kill PID $pid (gap=$gap_id age=${age_s}s status=$gap_status)"
        emit "bot_merge_watchdog_dry_run" \
            "\"pid\":$pid,\"gap\":\"$gap_id\",\"age_s\":$age_s,\"gap_status\":\"$gap_status\""
        return
    fi
    echo "[bot-merge-watchdog] killing PID $pid (gap=$gap_id age=${age_s}s status=$gap_status pr=${pr_status:-?})"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$pid" 2>/dev/null || true
    # Remove matching lease file.
    for lf in "$LOCK_DIR"/claim-*.json; do
        [ -f "$lf" ] || continue
        if grep -q "\"$pid\"" "$lf" 2>/dev/null; then
            rm -f "$lf"; break
        fi
        if [[ -n "$gap_id" ]]; then
            _gap_lower=$(printf '%s' "$gap_id" | tr '[:upper:]' '[:lower:]')
            [[ "$lf" == *"$_gap_lower"* ]] && { rm -f "$lf"; break; }
        fi
    done
    emit "bot_merge_watchdog_killed" \
        "\"pid\":$pid,\"gap\":\"$gap_id\",\"age_s\":$age_s,\"gap_status\":\"$gap_status\",\"pr_status\":\"$pr_status\""
    killed=$((killed + 1))
}

# ── Source 1: .health file scan (INFRA-1315) ─────────────────────────────────
# Health files contain gap_ids field (written by bot-merge.sh _bm_health_write).
# These processes may be young (<MAX_AGE_S) but still zombie if gap already done.
for hf in "$LOCK_DIR"/bot-merge-*.health; do
    [[ -f "$hf" ]] || continue
    pid="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('pid',''))" "$hf" 2>/dev/null || echo "")"
    gap_ids_hf="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('gap_ids',''))" "$hf" 2>/dev/null || echo "")"
    [[ -z "$pid" || -z "$gap_ids_hf" ]] && continue
    # Skip if already dead.
    kill -0 "$pid" 2>/dev/null || { rm -f "$hf" 2>/dev/null || true; continue; }
    # Check each gap.
    for gid in $gap_ids_hf; do
        [[ -z "$gid" ]] && continue
        gs="$(_gap_status "$gid")"
        if [[ "$gs" == "done" ]]; then
            age_s="$(_process_age_s "$pid")"
            _kill_process "$pid" "$gid" "$age_s" "done" ""
            rm -f "$hf" 2>/dev/null || true
            _handled_pids+=("$pid")
            break
        fi
    done
done

# ── Source 2: pgrep process scan (INFRA-1006 + INFRA-1315 age-gate fix) ──────
# INFRA-1315 fix: gap-done check runs BEFORE the age gate so young processes
# whose gap already shipped get killed promptly instead of lingering 30 min.
while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue

    # Skip already-handled PIDs (from health file scan above).
    for hp in "${_handled_pids[@]:-}"; do
        [[ "$hp" == "$pid" ]] && continue 2
    done

    # Respect per-process opt-out.
    proc_env=$(cat /proc/"$pid"/environ 2>/dev/null | tr '\0' '\n' | grep '^CHUMP_BOT_MERGE_NO_WATCHDOG=' || \
               ps eww -p "$pid" 2>/dev/null | grep -o 'CHUMP_BOT_MERGE_NO_WATCHDOG=[^ ]*' || true)
    [[ "$proc_env" == *"CHUMP_BOT_MERGE_NO_WATCHDOG=1"* ]] && continue

    # Extract gap ID from the command line (bot-merge.sh --gap INFRA-NNN).
    cmdline=$(ps -p "$pid" -o args= 2>/dev/null || cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ' || true)
    gap_id=$(echo "$cmdline" | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)

    # ── INFRA-1315: check gap status BEFORE age gate ─────────────────────────
    gap_status="unknown"
    pr_status="unknown"
    if [[ -n "$gap_id" ]] && command -v "$CHUMP_CMD" &>/dev/null; then
        gap_status="$(_gap_status "$gap_id")"
        if [[ "$gap_status" != "done" ]]; then
            closed_pr=$("$CHUMP_CMD" gap show "$gap_id" 2>/dev/null \
                | grep -E 'closed_pr:' | awk '{print $2}' || echo "")
            if [[ -n "$closed_pr" && "$closed_pr" != "null" ]]; then
                pr_num="${closed_pr##*/}"
                pr_state=$(gh api repos/"$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"/pulls/"$pr_num" \
                    --jq '.state' 2>/dev/null || echo "unknown")
                pr_status="$pr_state"
            fi
        fi
    fi

    should_kill=0
    if [[ "$gap_status" == "done" ]]; then
        should_kill=1
    elif [[ "$pr_status" == "closed" || "$pr_status" == "merged" ]]; then
        should_kill=1
    fi

    if [[ "$should_kill" -eq 1 ]]; then
        age_s="$(_process_age_s "$pid")"
        _kill_process "$pid" "$gap_id" "$age_s" "$gap_status" "$pr_status"
        continue
    fi

    # Gap still open — only warn if over the age limit.
    age_s="$(_process_age_s "$pid")"
    [[ "$age_s" -lt "$MAX_AGE_S" ]] && continue

    echo "[bot-merge-watchdog] WARN: PID $pid (gap=$gap_id age=${age_s}s) over limit but gap open — operator review needed"
    emit "bot_merge_watchdog_stuck" \
        "\"pid\":$pid,\"gap\":\"$gap_id\",\"age_s\":$age_s,\"gap_status\":\"$gap_status\",\"pr_status\":\"$pr_status\""
    warned=$((warned + 1))
done < <(pgrep -f 'bot-merge\.sh' 2>/dev/null || true)

echo "[bot-merge-watchdog] done: killed=$killed warned=$warned dry_run=$DRY_RUN (max_age=${MAX_AGE_S}s)"
