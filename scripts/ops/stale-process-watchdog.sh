#!/usr/bin/env bash
# stale-process-watchdog.sh — INFRA-1663
#
# Generalizes INFRA-1662 (claude-binary reaper) to the long tail of leaked
# fleet subprocesses. 2026-05-22 cleanup found 5 leaked rustc compilations
# (1.5 days old) and 2 leaked `chump health --slo-check` invocations (11+ h).
# Both classes leak via the same mechanism: worker dies, child keeps running
# indefinitely.
#
# Algorithm:
#   1. Scan ps -Ao pid,etime,comm,args for processes matching the lifetime
#      table below (one regex per class).
#   2. For each match, compare etime against its class's expected lifetime.
#   3. If etime > expected, SIGTERM with 30s grace, then SIGKILL stragglers.
#   4. Emit `kind=stale_process_reaped` with comm/etime/expected/pid fields.
#   5. Always emit a heartbeat (count=0 records prove the watchdog is alive).
#
# Idempotent: safe to run every 30 min; double-running won't double-kill
# (SIGTERM on an already-dead PID just returns 1 silently).
#
# Env:
#   CHUMP_STALE_PROC_WATCHDOG    set to 0 to no-op (bypass)
#   CHUMP_AMBIENT_LOG            override ambient.jsonl path
#   CHUMP_STALE_PROC_PS_BIN      override ps binary (test harness)
#   CHUMP_STALE_PROC_KILL_BIN    override kill binary (test harness)
#   CHUMP_STALE_PROC_DRY_RUN     1 = identify + emit, do not actually kill
#   CHUMP_STALE_PROC_GRACE_S     override SIGTERM→SIGKILL grace (default 30)
#   REPO_ROOT                    override repo root (default: derived)
#
# Lifetime table (class:regex:expected_seconds):
#   rustc            10 min   matches: rustc
#   cargo            15 min   matches: cargo
#   chump health      2 min   matches: chump health
#   worker.sh         4 h     matches: worker.sh
#   bot-merge.sh     20 min   matches: bot-merge.sh
#   run-fleet.sh     24 h     matches: run-fleet.sh
#
# Exit codes:
#   0  normal (whether or not anything was killed)
#   0  bypass via CHUMP_STALE_PROC_WATCHDOG=0
#   2  internal failure (ps unavailable, etc.)

set -euo pipefail

# ── Bypass ───────────────────────────────────────────────────────────────────
if [[ "${CHUMP_STALE_PROC_WATCHDOG:-1}" == "0" ]]; then
    echo "[stale-proc-watchdog] CHUMP_STALE_PROC_WATCHDOG=0 — exiting"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
PS_BIN="${CHUMP_STALE_PROC_PS_BIN:-ps}"
KILL_BIN="${CHUMP_STALE_PROC_KILL_BIN:-kill}"
DRY_RUN="${CHUMP_STALE_PROC_DRY_RUN:-0}"
GRACE_S="${CHUMP_STALE_PROC_GRACE_S:-30}"

# ── Lifetime table ───────────────────────────────────────────────────────────
# Class label, command-match regex (against the args column), expected lifetime
# in seconds. Order matters: first match wins, so more-specific patterns must
# precede generic ones (e.g. `chump health` before `chump`).
#
# Bash 3.2 has no associative arrays. Parallel arrays it is.
CLASS_LABELS=(
    "chump health"
    "bot-merge.sh"
    "worker.sh"
    "run-fleet.sh"
    "rustc"
    "cargo"
)
CLASS_REGEX=(
    'chump[[:space:]]+health'
    'bot-merge\.sh'
    'worker\.sh'
    'run-fleet\.sh'
    '(^|/)rustc([[:space:]]|$)'
    '(^|/)cargo([[:space:]]|$)'
)
CLASS_EXPECT=(
    120        # chump health
    1200       # bot-merge.sh
    14400      # worker.sh
    86400      # run-fleet.sh
    600        # rustc
    900        # cargo
)

# ── Read ps ──────────────────────────────────────────────────────────────────
# Format: PID ETIME COMM ARGS
# etime format is `[[DD-]hh:]mm:ss`; convert below.
PS_OUTPUT="$("$PS_BIN" -A -o pid=,etime=,comm=,args= 2>/dev/null || true)"
if [[ -z "$PS_OUTPUT" ]]; then
    echo "[stale-proc-watchdog] ps returned no output" >&2
    exit 2
fi

# ── etime → seconds ──────────────────────────────────────────────────────────
etime_to_secs() {
    local t="$1"
    local d=0 h=0 m=0 s=0
    if [[ "$t" == *-* ]]; then
        d="${t%%-*}"
        t="${t#*-}"
    fi
    local n
    n=$(echo "$t" | awk -F: '{print NF}')
    if [[ "$n" == "3" ]]; then
        h="${t%%:*}"; t="${t#*:}"
        m="${t%%:*}"; s="${t#*:}"
    elif [[ "$n" == "2" ]]; then
        m="${t%%:*}"; s="${t#*:}"
    else
        s="$t"
    fi
    d=$((10#${d:-0})); h=$((10#${h:-0})); m=$((10#${m:-0})); s=$((10#${s:-0}))
    echo $((d*86400 + h*3600 + m*60 + s))
}

# ── Classify rows + collect stale candidates ─────────────────────────────────
# Parallel arrays describing each stale process found this sweep.
STALE_PIDS=()
STALE_CLASSES=()
STALE_ETIMES=()
STALE_EXPECTS=()
STALE_COMMS=()

# Self-exclusion: never reap our own PID or the parent shell that invoked us
# (otherwise a launchd-spawned bash wrapper running this script could match
# `worker.sh` patterns transitively).
SELF_PID="$$"
SELF_PPID="${PPID:-0}"

NCLASSES="${#CLASS_LABELS[@]}"

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Trim leading whitespace then parse the three fixed fields + the args tail.
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%% *}"; line="${line#* }"; line="${line#"${line%%[![:space:]]*}"}"
    et="${line%% *}";  line="${line#* }"; line="${line#"${line%%[![:space:]]*}"}"
    comm="${line%% *}"; line="${line#* }"; line="${line#"${line%%[![:space:]]*}"}"
    args="$line"

    [[ -z "$pid" || -z "$et" ]] && continue
    [[ "$pid" == "$SELF_PID" || "$pid" == "$SELF_PPID" ]] && continue

    # Match against the lifetime table. First hit wins.
    matched_idx=-1
    i=0
    while (( i < NCLASSES )); do
        re="${CLASS_REGEX[$i]}"
        if [[ "$args" =~ $re ]] || [[ "$comm" =~ $re ]]; then
            matched_idx=$i
            break
        fi
        i=$((i+1))
    done
    (( matched_idx < 0 )) && continue

    et_s="$(etime_to_secs "$et")"
    expected="${CLASS_EXPECT[$matched_idx]}"
    if (( et_s <= expected )); then
        continue   # fresh enough; leave it alone
    fi

    STALE_PIDS+=("$pid")
    STALE_CLASSES+=("${CLASS_LABELS[$matched_idx]}")
    STALE_ETIMES+=("$et_s")
    STALE_EXPECTS+=("$expected")
    STALE_COMMS+=("$comm")
done <<< "$PS_OUTPUT"

# ── Reap (SIGTERM + grace + SIGKILL) ─────────────────────────────────────────
STALE_COUNT=${#STALE_PIDS[@]}
KILLED=0

mkdir -p "$(dirname "$AMBIENT_LOG")"

emit_event() {
    # $1=pid $2=comm $3=etime $4=expected $5=class $6=action
    local ts pid comm et exp class action
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    pid="$1"; comm="$2"; et="$3"; exp="$4"; class="$5"; action="$6"
    printf '{"ts":"%s","kind":"stale_process_reaped","pid":%s,"comm":"%s","class":"%s","etime_secs":%s,"expected_secs":%s,"action":"%s","dry_run":%s}\n' \
        "$ts" "$pid" "$comm" "$class" "$et" "$exp" "$action" \
        "$([[ "$DRY_RUN" == "1" ]] && echo true || echo false)" \
        >> "$AMBIENT_LOG"
}

# SIGTERM pass
i=0
TERMED_PIDS=()
while (( i < STALE_COUNT )); do
    pid="${STALE_PIDS[$i]}"
    comm="${STALE_COMMS[$i]}"
    et="${STALE_ETIMES[$i]}"
    exp="${STALE_EXPECTS[$i]}"
    class="${STALE_CLASSES[$i]}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[stale-proc-watchdog] DRY-RUN would SIGTERM pid=$pid class=$class etime=${et}s expected=${exp}s"
        emit_event "$pid" "$comm" "$et" "$exp" "$class" "sigterm"
        KILLED=$((KILLED+1))
    else
        if "$KILL_BIN" -TERM "$pid" 2>/dev/null; then
            TERMED_PIDS+=("$pid:$i")
            emit_event "$pid" "$comm" "$et" "$exp" "$class" "sigterm"
        fi
    fi
    i=$((i+1))
done

# Grace + SIGKILL stragglers (skipped under DRY_RUN — fake PIDs don't exist).
if [[ "$DRY_RUN" != "1" ]] && (( ${#TERMED_PIDS[@]} > 0 )); then
    sleep "$GRACE_S"
    for entry in "${TERMED_PIDS[@]}"; do
        pid="${entry%%:*}"
        idx="${entry#*:}"
        # Still alive? kill -0 returns 0 if so.
        if "$KILL_BIN" -0 "$pid" 2>/dev/null; then
            if "$KILL_BIN" -KILL "$pid" 2>/dev/null; then
                emit_event "$pid" "${STALE_COMMS[$idx]}" "${STALE_ETIMES[$idx]}" \
                    "${STALE_EXPECTS[$idx]}" "${STALE_CLASSES[$idx]}" "sigkill"
                KILLED=$((KILLED+1))
            fi
        else
            # Process exited within the grace window — SIGTERM was sufficient.
            KILLED=$((KILLED+1))
        fi
    done
fi

# ── Heartbeat record (count=0 sweep proves the watchdog is alive) ────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"stale_process_reaped","sweep":true,"count":%d,"dry_run":%s}\n' \
    "$TS" "$STALE_COUNT" \
    "$([[ "$DRY_RUN" == "1" ]] && echo true || echo false)" \
    >> "$AMBIENT_LOG"

echo "[stale-proc-watchdog] candidates=$STALE_COUNT killed=$KILLED grace=${GRACE_S}s dry_run=$DRY_RUN"
