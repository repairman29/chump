#!/usr/bin/env bash
# reap-orphan-claude-procs.sh — INFRA-1662
#
# Reap orphan `claude` binary subprocesses leaked by long-running autonomous
# loops (/loop, ScheduleWakeup, CronCreate). The Claude Code harness historically
# does not waitpid the child between firings; cron-loop 6249a56f leaked 354
# wedged subprocesses over 60h, pinning 8.5GB RAM and pushing load avg to 262.
#
# Algorithm:
#   1. Find the foreground Claude.app PID (parent of all legitimate sessions).
#   2. List every `claude` binary process (the `claude --output-format stream-json`
#      ones, NOT the desktop Claude.app itself).
#   3. For each, walk the ppid chain. If the chain reaches the foreground
#      Claude.app PID, it is a legitimate live session — skip.
#   4. Otherwise it's an orphan. If etime > REAP_AGE (default 3600s = 1h),
#      SIGKILL it (SIGTERM has been empirically observed not to reach these).
#   5. Emit `kind=orphan_subprocess_reaped` with count + age + RSS aggregates.
#
# Idempotent: safe to run every minute.
#
# Env:
#   REAP_AGE                   default 3600   minimum etime in seconds before kill
#   CHUMP_REAPER_DISABLED      set to 1 to no-op (bypass)
#   CHUMP_AMBIENT_LOG          override ambient.jsonl path
#   REPO_ROOT                  override repo root (default: derived)
#
# Exit codes:
#   0  normal (whether or not anything was killed)
#   0  bypass via CHUMP_REAPER_DISABLED
#   2  internal failure (ps unavailable, etc.)

set -euo pipefail

# ── Bypass ───────────────────────────────────────────────────────────────────
if [[ "${CHUMP_REAPER_DISABLED:-0}" == "1" ]]; then
    echo "[claude-reaper] CHUMP_REAPER_DISABLED=1 — exiting"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
REAP_AGE="${REAP_AGE:-3600}"

# Allow tests to override the `ps` binary (PATH shim is the cleaner way; this
# is a belt-and-braces fallback for cases where the test runner can't manipulate
# PATH cleanly).
PS_BIN="${CHUMP_REAPER_PS_BIN:-ps}"
KILL_BIN="${CHUMP_REAPER_KILL_BIN:-kill}"
# CHUMP_REAPER_DRY_RUN=1 → identify orphans, emit event, but do not actually
# SIGKILL. Used by the test harness so it can stub `ps` output without needing
# real PIDs to exist.
DRY_RUN="${CHUMP_REAPER_DRY_RUN:-0}"

# ── 1. Foreground Claude.app PID ─────────────────────────────────────────────
# We use pgrep against the macOS app bundle path. If absent (e.g. headless
# Linux CI), FG_PID is empty and *every* claude binary becomes a candidate
# for reaping (which is fine on a headless host — there's no foreground
# Claude to protect).
FG_PID=""
if command -v pgrep >/dev/null 2>&1; then
    FG_PID="$(pgrep -f '/Applications/Claude.app/Contents/MacOS/Claude' 2>/dev/null | head -1 || true)"
fi

# ── 2. Build ppid table: child_pid<TAB>parent_pid<TAB>etime_secs<TAB>rss ─────
# bash 3.2 (default /bin/bash on macOS, used by launchd) lacks associative
# arrays. We use a temp file as the lookup table. Single ps call, parsed once.
PPID_TBL="$(mktemp -t claude-reaper-ppid-XXXXXX)"
CAND_FILE="$(mktemp -t claude-reaper-cand-XXXXXX)"
cleanup() { rm -f "$PPID_TBL" "$CAND_FILE"; }
trap cleanup EXIT

# ps output: PID PPID ELAPSED RSS COMMAND...
# etime format is `[[DD-]hh:]mm:ss`; we convert below.
PS_OUTPUT="$("$PS_BIN" -A -o pid=,ppid=,etime=,rss=,command= 2>/dev/null || true)"
if [[ -z "$PS_OUTPUT" ]]; then
    echo "[claude-reaper] ps returned no output" >&2
    exit 2
fi

# Convert ps etime ([[DD-]hh:]mm:ss) to seconds.
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

# Parse ps output into PPID_TBL + candidate list
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%% *}"; line="${line#* }"; line="${line#"${line%%[![:space:]]*}"}"
    ppid="${line%% *}"; line="${line#* }"; line="${line#"${line%%[![:space:]]*}"}"
    et="${line%% *}"; line="${line#* }"; line="${line#"${line%%[![:space:]]*}"}"
    rss="${line%% *}"; line="${line#* }"; line="${line#"${line%%[![:space:]]*}"}"
    cmd="$line"

    [[ -z "$pid" || -z "$ppid" ]] && continue

    et_s="$(etime_to_secs "$et")"
    printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$et_s" "$rss" >> "$PPID_TBL"

    # Identify candidates: the leaked binary lives at
    # ~/Library/Application Support/Claude/claude-code/<ver>/claude.app/Contents/MacOS/claude
    # invoked with `--output-format stream-json` (or similar).
    # Exclude the foreground desktop Claude.app explicitly.
    case "$cmd" in
        */Applications/Claude.app/Contents/MacOS/Claude*) ;;  # foreground app — skip
        *claude-code*claude.app/Contents/MacOS/claude*|*claude\ --output-format*|*\ claude\ -p\ *|*/claude\ --output-format*)
            printf '%s\n' "$pid" >> "$CAND_FILE"
            ;;
    esac
done <<< "$PS_OUTPUT"

# Lookup helpers (tab-delimited PPID_TBL: pid<TAB>ppid<TAB>etime_s<TAB>rss).
lookup_field() {
    # $1=pid  $2=field-number (2=ppid, 3=etime_s, 4=rss)
    awk -v p="$1" -v f="$2" -F'\t' '$1==p {print $f; exit}' "$PPID_TBL"
}

# ── 3. Walk ppid chain — does it lead to FG_PID? ─────────────────────────────
chain_reaches_fg() {
    local pid="$1"
    [[ -z "$FG_PID" ]] && return 1
    local guard=0
    while [[ -n "$pid" && "$pid" != "1" && "$pid" != "0" && $guard -lt 64 ]]; do
        [[ "$pid" == "$FG_PID" ]] && return 0
        pid="$(lookup_field "$pid" 2)"
        guard=$((guard+1))
    done
    return 1
}

# ── 4. Classify + reap ───────────────────────────────────────────────────────
ORPHAN_PIDS=()
OLDEST_ETIME=0
TOTAL_RSS=0
CAND_COUNT=0
if [[ -s "$CAND_FILE" ]]; then
    CAND_COUNT="$(wc -l < "$CAND_FILE" | tr -d ' ')"
fi
ORPHAN_ETIMES=()
if [[ -s "$CAND_FILE" ]]; then
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        et="$(lookup_field "$pid" 3)"; et="${et:-0}"
        rss="$(lookup_field "$pid" 4)"; rss="${rss:-0}"

        if chain_reaches_fg "$pid"; then
            continue   # legitimate live session — never touch
        fi

        if (( et < REAP_AGE )); then
            continue   # young; still useful or about to be reaped naturally
        fi

        ORPHAN_PIDS+=("$pid")
        ORPHAN_ETIMES+=("$et")
        (( et > OLDEST_ETIME )) && OLDEST_ETIME=$et
        TOTAL_RSS=$((TOTAL_RSS + rss))
    done < "$CAND_FILE"
fi

KILLED=0
ORPHAN_COUNT=${#ORPHAN_PIDS[@]}
i=0
while (( i < ORPHAN_COUNT )); do
    pid="${ORPHAN_PIDS[$i]}"
    et="${ORPHAN_ETIMES[$i]}"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[claude-reaper] DRY-RUN would SIGKILL pid=$pid etime=${et}s"
        KILLED=$((KILLED+1))
    else
        if "$KILL_BIN" -9 "$pid" 2>/dev/null; then
            KILLED=$((KILLED+1))
        fi
    fi
    i=$((i+1))
done

# ── 5. Emit ambient event ────────────────────────────────────────────────────
# Always emit a record so the daemon's heartbeat is visible — count=0 lines
# prove the watchdog is alive and finding nothing to do (the healthy steady
# state). Drift gates can flag total silence as a separate concern.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$AMBIENT_LOG")"
printf '{"ts":"%s","kind":"orphan_subprocess_reaped","count":%d,"oldest_etime_secs":%d,"total_rss_kb":%d,"reap_age_secs":%d,"fg_pid":"%s","dry_run":%s}\n' \
    "$TS" "$KILLED" "$OLDEST_ETIME" "$TOTAL_RSS" "$REAP_AGE" "${FG_PID:-}" \
    "$([[ "$DRY_RUN" == "1" ]] && echo true || echo false)" \
    >> "$AMBIENT_LOG"

echo "[claude-reaper] candidates=$CAND_COUNT orphans=$ORPHAN_COUNT killed=$KILLED oldest_etime=${OLDEST_ETIME}s total_rss_kb=$TOTAL_RSS fg_pid=${FG_PID:-none}"
