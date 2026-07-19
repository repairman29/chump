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
#      Uses a multi-probe strategy (pgrep → ps|awk → launchctl) to handle
#      macOS pgrep quirks with dotted bundle paths (INFRA-1786).
#   2. List every `claude` binary process (the `claude --output-format stream-json`
#      ones, NOT the desktop Claude.app itself).
#   3. For each, walk the ppid chain. If the chain reaches the foreground
#      Claude.app PID, it is a legitimate live session — skip.
#   4. Otherwise it's an orphan. If etime > REAP_AGE (default 3600s = 1h),
#      SIGKILL it (SIGTERM has been empirically observed not to reach these).
#   5. Emit `kind=orphan_subprocess_reaped` with count + age + RSS aggregates.
#
# Safety gate (INFRA-1786):
#   If fg_pid cannot be determined AND CHUMP_REAPER_HEADLESS is NOT set to "1",
#   the script REFUSES to operate (exits 3). On a developer workstation this
#   protects active fleet workers that would otherwise be mass-reaped.
#   Set CHUMP_REAPER_HEADLESS=1 to restore the old reap-everything behaviour
#   for CI/headless environments.
#
# Idempotent: safe to run every minute.
#
# Env:
#   REAP_AGE                   default 3600   minimum etime in seconds before kill
#   CHUMP_REAPER_DISABLED      set to 1 to no-op (bypass)
#   CHUMP_REAPER_HEADLESS      set to 1 to allow reap-all when fg_pid is empty
#   CHUMP_AMBIENT_LOG          override ambient.jsonl path
#   REPO_ROOT                  override repo root (default: derived)
#   CHUMP_REAPER_PGREP_BIN     override pgrep binary for tests
#
# Exit codes:
#   0  normal (whether or not anything was killed)
#   0  bypass via CHUMP_REAPER_DISABLED
#   2  internal failure (ps unavailable, etc.)
#   3  safety gate: fg_pid=none on macOS without CHUMP_REAPER_HEADLESS=1

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

# ── INFRA-1851: PTY-pressure urgent mode ─────────────────────────────────────
# When the count of allocated /dev/ttys??? device files exceeds 80% of the
# kernel limit (kern.tty.ptmx_max), the operator's machine is minutes away
# from refusing new shells / tmux panes / SSH sessions. The 3600s age
# threshold means a fresh leak takes up to ~65 min to drain on the next
# regular sweep — too slow once we're already near the cap.
#
# Behaviour: detect pressure at the top of the run; if pressured AND no
# operator-supplied REAP_AGE override is in play, drop the effective age
# floor to CHUMP_REAPER_PRESSURE_AGE (default 600s = 10 min) so this sweep
# catches anything started in the last hour, not just the last hour-plus.
#
# Tunables:
#   CHUMP_REAPER_PRESSURE_THRESHOLD  default 65  percent of ptmx_max (INFRA-1930:
#                                                 lowered from 80 — combined with
#                                                 the 120s cadence, catches
#                                                 pressure climbing instead of
#                                                 only after it saturates)
#   CHUMP_REAPER_PRESSURE_AGE        default 600 fallback REAP_AGE when pressured
#   CHUMP_REAPER_PRESSURE_DISABLED   set to 1 to skip pressure check entirely
#
# Emits kind=reaper_pty_pressure (with allocated/limit/threshold/new_age)
# so dashboards can see when the urgent mode trips. Safe-by-default: if
# the detection probes fail (missing sysctl / ls), no pressure assumption
# is made and REAP_AGE stays at its operator-supplied value.
if [ "${CHUMP_REAPER_PRESSURE_DISABLED:-0}" != "1" ]; then
    _pty_limit=$(sysctl -n kern.tty.ptmx_max 2>/dev/null || echo "")
    # `ls /dev/ttys???` returns non-zero when no glob matches (Linux CI has
    # no such device files — uses /dev/pts/N instead). The script's
    # `set -euo pipefail` would otherwise kill on the failed pipeline; the
    # `|| true` makes the count 0 on no-match without aborting the sweep.
    _pty_alloc=$(ls /dev/ttys??? 2>/dev/null | wc -l | awk '{print $1}' || true)
    _pty_alloc="${_pty_alloc:-0}"
    _pty_threshold_pct="${CHUMP_REAPER_PRESSURE_THRESHOLD:-65}"
    _pty_pressure_age="${CHUMP_REAPER_PRESSURE_AGE:-600}"
    if [ -n "$_pty_limit" ] && [ "$_pty_limit" -gt 0 ] && [ "$_pty_alloc" -gt 0 ]; then
        # integer percent — avoids bc dependency on shells without it
        _pty_pct=$(( _pty_alloc * 100 / _pty_limit ))
        if [ "$_pty_pct" -ge "$_pty_threshold_pct" ]; then
            # only override if operator did NOT explicitly set REAP_AGE
            if [ -z "${REAP_AGE_OVERRIDE_SOURCE:-}" ] && [ -z "${_REAP_AGE_SET:-}" ]; then
                REAP_AGE="$_pty_pressure_age"
            fi
            _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
            printf '{"ts":"%s","kind":"reaper_pty_pressure","allocated":%d,"limit":%d,"pct":%d,"threshold":%d,"new_reap_age":%d}\n' \
                "$_ts" "$_pty_alloc" "$_pty_limit" "$_pty_pct" "$_pty_threshold_pct" "$REAP_AGE" \
                >> "$AMBIENT_LOG" 2>/dev/null || true
        fi
    fi
fi

# Allow tests to override the `ps` binary (PATH shim is the cleaner way; this
# is a belt-and-braces fallback for cases where the test runner can't manipulate
# PATH cleanly).
PS_BIN="${CHUMP_REAPER_PS_BIN:-ps}"
KILL_BIN="${CHUMP_REAPER_KILL_BIN:-kill}"
PGREP_BIN="${CHUMP_REAPER_PGREP_BIN:-pgrep}"
# CHUMP_REAPER_DRY_RUN=1 → identify orphans, emit event, but do not actually
# SIGKILL. Used by the test harness so it can stub `ps` output without needing
# real PIDs to exist.
DRY_RUN="${CHUMP_REAPER_DRY_RUN:-0}"

# ── 1. Foreground Claude.app PID ─────────────────────────────────────────────
# Multi-probe strategy to handle macOS pgrep quirks with dotted bundle paths
# (INFRA-1786). Tries three approaches in order; first non-empty result wins.
#
# Probe A: pgrep -f (may silently fail on macOS with bundle paths)
# Probe B: ps -A | awk  (more reliable for bundle-path matching)
# Probe C: launchctl print  (reads service registry directly)
#
# If all probes return empty AND CHUMP_REAPER_HEADLESS != "1", we refuse to
# operate to avoid mass-reaping active fleet workers (safety gate, INFRA-1786).
CLAUDE_APP_PATH='/Applications/Claude.app/Contents/MacOS/Claude'
FG_PID=""

# Probe A: pgrep -f
if [[ -z "$FG_PID" ]] && command -v "$PGREP_BIN" >/dev/null 2>&1; then
    FG_PID="$("$PGREP_BIN" -f "$CLAUDE_APP_PATH" 2>/dev/null | head -1 || true)"
fi

# Probe B: ps -A -o pid,command | awk (matches the literal path in the command column)
if [[ -z "$FG_PID" ]]; then
    FG_PID="$("$PS_BIN" -A -o pid=,command= 2>/dev/null \
        | awk -v path="$CLAUDE_APP_PATH" '$0 ~ path {print $1; exit}' \
        || true)"
fi

# Probe C: launchctl print — reads the service registry and extracts the PID
# Only available on macOS (launchctl with print subcommand).
if [[ -z "$FG_PID" ]] && command -v launchctl >/dev/null 2>&1; then
    FG_PID="$(launchctl print gui/"$(id -u)" 2>/dev/null \
        | awk '/Claude/ && /pid/ {match($0, /pid = ([0-9]+)/, a); if (a[1]) {print a[1]; exit}}' \
        || true)"
fi

# Safety gate: if we still have no fg_pid and we're not in headless mode,
# refuse to operate to avoid mass-reaping active fleet workers.
if [[ -z "$FG_PID" && "${CHUMP_REAPER_HEADLESS:-0}" != "1" ]]; then
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT_LOG")"
    printf '{"ts":"%s","kind":"reaper_safety_gate_triggered","reason":"fg_pid_none","headless":false}\n' \
        "$TS" >> "$AMBIENT_LOG"
    echo "fg_pid=none on macOS without CHUMP_REAPER_HEADLESS=1 — refusing to reap everything" >&2
    exit 3
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
