# shellcheck shell=bash
# reaper-instrumentation.sh — shared helpers for stale-*-reaper.sh scripts.
#
# Provides three things every reaper needs (INFRA-120, 2026-05-01):
#   1. reaper_emit_run NAME STATUS COUNTS_JSON
#        Emits one `kind=reaper_run` event into .chump-locks/ambient.jsonl
#        AND stamps a heartbeat file at /tmp/chump-reaper-NAME.heartbeat
#        (the watchdog reads the heartbeat to detect missed runs).
#
#   2. reaper_rotate_log PATH MAX_BYTES
#        Truncates a log file to the most-recent MAX_BYTES (default 5MB) by
#        rotating PATH → PATH.1 once it exceeds the cap. Cheap; safe to call
#        every run. Keeps two generations on disk (PATH and PATH.1).
#
#   3. reaper_setup NAME
#        One-line setup that resolves the main repo root (works from a
#        worktree), exports REAPER_NAME / REAPER_REPO_ROOT / REAPER_LOCK_DIR
#        / REAPER_HEARTBEAT, and starts a wall-clock timer. Pair with
#        reaper_finish to emit a single reaper_run event with elapsed seconds.
#
# Source from the top of every reaper:
#   source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
#   reaper_setup pr            # or worktree, branch, etc.
#   ... do work, accumulate counts ...
#   reaper_finish ok '{"closed":3,"warned":1}'
#
# Designed to be Bash 3.2+ compatible (macOS default) and dependency-light:
# uses python3 for JSON only when available, falls back to a hand-rolled
# emitter so heartbeat stamping always works (the watchdog grades on the
# heartbeat, not on JSON validity).

# Resolve main repo root from any worktree. Linked worktrees have a separate
# --show-toplevel but share --git-common-dir, so the canonical root is the
# parent of --git-common-dir.
_reaper_main_repo() {
    local common
    common="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
    if [[ "$common" == ".git" ]]; then
        git rev-parse --show-toplevel 2>/dev/null || pwd
    else
        # common is .git or /abs/path/.git; main repo root is its parent.
        (cd "$common/.." && pwd)
    fi
}

# reaper_setup NAME — call once at the top of a reaper script.
reaper_setup() {
    REAPER_NAME="${1:?reaper_setup needs a name}"
    REAPER_REPO_ROOT="$(_reaper_main_repo)"
    REAPER_LOCK_DIR="$REAPER_REPO_ROOT/.chump-locks"
    REAPER_HEARTBEAT="/tmp/chump-reaper-${REAPER_NAME}.heartbeat"
    REAPER_START_EPOCH="$(date +%s)"
    mkdir -p "$REAPER_LOCK_DIR" 2>/dev/null || true
}

# reaper_rotate_log PATH [MAX_BYTES]
# Rotate PATH → PATH.1 when it exceeds MAX_BYTES (default 5_242_880 = 5 MB).
# A no-op if the file doesn't exist or is under cap. Keeps exactly one
# generation; the launchd-managed /tmp logs are noisy and not historically
# valuable.
reaper_rotate_log() {
    local path="$1"
    local max="${2:-5242880}"
    [[ -f "$path" ]] || return 0
    local size
    if size=$(stat -f%z "$path" 2>/dev/null); then
        :  # macOS / BSD stat
    else
        size=$(stat -c%s "$path" 2>/dev/null || echo 0)
    fi
    if [[ "${size:-0}" -gt "$max" ]]; then
        mv -f "$path" "${path}.1" 2>/dev/null || true
        : > "$path" 2>/dev/null || true
    fi
}

# reaper_emit_run NAME STATUS COUNTS_JSON [DURATION_SECS]
# Append a kind=reaper_run event to ambient.jsonl AND stamp the heartbeat.
# COUNTS_JSON is a free-form JSON object (e.g. '{"closed":3,"warned":1}').
# Heartbeat is stamped FIRST so the watchdog still sees a recent run even if
# the JSON emit fails on a corrupted ambient.jsonl.
reaper_emit_run() {
    local name="${1:?reaper_emit_run needs name}"
    local status="${2:?reaper_emit_run needs status}"
    local counts="${3:-}"
    [[ -z "$counts" ]] && counts='{}'
    local duration="${4:-0}"

    local heartbeat="/tmp/chump-reaper-${name}.heartbeat"
    local lock_dir="${REAPER_LOCK_DIR:-$(_reaper_main_repo)/.chump-locks}"
    local ambient="$lock_dir/ambient.jsonl"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # 1. Stamp heartbeat (always, even on dry runs).
    {
        echo "ts=$ts"
        echo "status=$status"
        echo "duration=$duration"
        echo "counts=$counts"
    } > "$heartbeat" 2>/dev/null || true

    # 2. Append to ambient.jsonl.
    mkdir -p "$lock_dir" 2>/dev/null || true
    local json
    if command -v python3 >/dev/null 2>&1; then
        json=$(python3 -c "
import json, sys
counts_raw = sys.argv[5]
try:
    counts = json.loads(counts_raw)
except Exception:
    counts = {'raw': counts_raw}
print(json.dumps({
    'event': 'reaper_run',
    'kind': 'reaper_run',
    'reaper': sys.argv[1],
    'status': sys.argv[2],
    'duration_secs': int(sys.argv[3]),
    'ts': sys.argv[4],
    'counts': counts,
}))
" "$name" "$status" "$duration" "$ts" "$counts" 2>/dev/null || true)
    fi
    if [[ -z "$json" ]]; then
        # Fallback emitter (no python3). Counts is embedded raw; consumers
        # tolerate this.
        json="{\"event\":\"reaper_run\",\"kind\":\"reaper_run\",\"reaper\":\"$name\",\"status\":\"$status\",\"duration_secs\":$duration,\"ts\":\"$ts\",\"counts\":$counts}"
    fi
    printf '%s\n' "$json" >> "$ambient" 2>/dev/null || true
}

# reaper_check_disk_headroom — INFRA-453 disk-headroom circuit breaker.
#
# Call once at the top of every reaper (after reaper_setup). Checks df on
# /tmp (heartbeat writes) and REAPER_LOCK_DIR (ambient.jsonl writes). If
# either has <5% free space, emits ALERT kind=disk_critical to ambient.jsonl
# and exits 0 — don't fail the launchd job, don't swallow the symptom.
#
# INFRA-973 (2026-05-13): reapers whose job IS to free disk (worktree)
# are exempt from the early-exit. They still emit the ALERT (operator
# visibility) but continue running, because aborting them creates a
# deadlock — cleanup is exactly what's needed when disk is low. Without
# this exemption the stale-worktree-reaper kept ALERTing for hours
# while doing 0 reaping on a 100%-full disk.
#
# RESILIENT-096 (2026-06-05): the event is deduped by df filesystem-source and
# carries a self-diagnosing `note` + `fs`/`mount` fields. On macOS APFS /tmp and
# the repo share ONE Data volume, so probing both used to emit two identical
# disk_critical events per run; we now emit at most one per backing filesystem.
# The note names the REAL full volume + mount point — `df /` shows only the tiny
# read-only system-volume footprint and misleads, because `/` and
# /System/Volumes/Data share one container free-pool (the Avail column). We key
# the dedup on the df source string (col 1), NOT `stat -f%d`: APFS reports the
# same container device id for `/` and the Data volume, so a stat-based key
# would wrongly conflate volumes with very different usage.
#
# Bypass: CHUMP_SKIP_DISK_HEADROOM=1 (tests / dev only).
# Per-reaper exempt: REAPER_FREES_DISK=1 set before calling.
reaper_check_disk_headroom() {
    [[ "${CHUMP_SKIP_DISK_HEADROOM:-0}" == "1" ]] && return 0
    local threshold="${CHUMP_DISK_CRITICAL_PCT:-5}"
    local lock_dir="${REAPER_LOCK_DIR:-$(_reaper_main_repo)/.chump-locks}"
    local ambient="$lock_dir/ambient.jsonl"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Always check /tmp (heartbeat dir) and the lock dir (ambient.jsonl dir).
    # Dedup by df filesystem-source (col 1) so we emit at most ONE disk_critical
    # per backing filesystem per run (RESILIENT-096). seen_fs is a |-delimited
    # set — portable to /bin/bash 3.2 (no associative arrays; the reaper plists
    # run under /bin/bash, which is 3.2 on macOS).
    local dirs=("/tmp" "$lock_dir")
    local triggered=0
    local dir
    local seen_fs="|"
    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || dir="$(dirname "$dir")"
        local df_out used_pct free_pct fs mount note
        df_out="$(df -Ph "$dir" 2>/dev/null | tail -1)" || continue
        fs="$(printf '%s\n' "$df_out" | awk '{print $1}')"
        mount="$(printf '%s\n' "$df_out" | awk '{print $NF}')"
        used_pct="$(printf '%s\n' "$df_out" | awk '{print $5}' | tr -d '%')"
        [[ "$used_pct" =~ ^[0-9]+$ ]] || continue
        # Skip a dir whose backing filesystem we've already evaluated this run.
        if [[ -n "$fs" && "$seen_fs" == *"|${fs}|"* ]]; then
            continue
        fi
        [[ -n "$fs" ]] && seen_fs="${seen_fs}${fs}|"
        free_pct=$(( 100 - used_pct ))
        if [[ "$free_pct" -lt "$threshold" ]]; then
            # Self-diagnosing note: name the REAL full filesystem + mount point
            # (not just the logical dir we probed), so the operator does not have
            # to re-run df or untangle the macOS APFS volume-vs-container split.
            note="filesystem ${fs} at ${mount} is ${free_pct}% free (<${threshold}% critical); probed via ${dir}"
            printf 'ALERT [disk_critical] %s: %d%% free (threshold %d%%). df: %s\n' \
                "$dir" "$free_pct" "$threshold" "$df_out" >&2
            mkdir -p "$lock_dir" 2>/dev/null || true
            printf '{"event":"ALERT","kind":"disk_critical","reaper":"%s","dir":"%s","fs":"%s","mount":"%s","free_pct":%d,"threshold_pct":%d,"note":"%s","ts":"%s","df":"%s"}\n' \
                "${REAPER_NAME:-unknown}" "$dir" "$fs" "$mount" "$free_pct" "$threshold" "$note" "$ts" "$df_out" \
                >> "$ambient" 2>/dev/null || true
            triggered=1
        fi
    done

    if [[ "$triggered" -eq 1 ]]; then
        # Reapers whose job IS to free disk must keep running on low disk.
        if [[ "${REAPER_FREES_DISK:-0}" == "1" ]] || [[ "${REAPER_NAME:-}" == "worktree" ]]; then
            printf '[%s] disk critically low — %s continuing because it frees disk (INFRA-973)\n' \
                "$ts" "${REAPER_NAME:-unknown}" >&2
            return 0
        fi
        printf '[%s] disk critically low — %s exiting early to avoid ENOSPC heartbeat failure\n' \
            "$ts" "${REAPER_NAME:-unknown}" >&2
        exit 0
    fi
}

# reaper_grade_watchdog — INFRA-452 cross-grade.
#
# The watchdog grades pr/worktree/branch/etc., but if the watchdog itself
# stops running (broken plist, dead python3, crashed launchd), nothing
# alerts. We can't rely on the watchdog to grade itself in that case.
# Solution: every reaper, on its own run, does a cheap one-stat check on
# the watchdog heartbeat. If it's stale (>WATCHDOG_THRESHOLD_SECS,
# default 90min — twice the watchdog's expected 30min cadence × 1.5x
# slop), the reaper emits a kind=watchdog_silent ALERT to ambient.jsonl
# so the next session pre-flight sees it. Decentralized — even if the
# watchdog is dead forever, the next reaper run picks it up.
#
# Skip-self-grade: the watchdog itself calls reaper_finish via its own
# code path; suppressing the cross-grade when REAPER_NAME=watchdog
# avoids a useless self-compare.
#
# Bypass: CHUMP_DISABLE_WATCHDOG_CROSSGRADE=1 (for tests / dev).
reaper_grade_watchdog() {
    [[ "${CHUMP_DISABLE_WATCHDOG_CROSSGRADE:-0}" == "1" ]] && return 0
    [[ "${REAPER_NAME:-}" == "watchdog" ]] && return 0
    local hb="/tmp/chump-reaper-watchdog.heartbeat"
    local threshold="${WATCHDOG_THRESHOLD_SECS:-5400}"  # 90 min default
    [[ -f "$hb" ]] || return 0  # Nothing yet — first install; the
                                # watchdog itself will alert next run.
    local last_ts last_epoch now age
    last_ts="$(grep '^ts=' "$hb" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    if [[ -n "$last_ts" ]]; then
        last_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" "+%s" 2>/dev/null \
                  || date -u -d "$last_ts" "+%s" 2>/dev/null \
                  || stat -f%m "$hb" 2>/dev/null \
                  || stat -c%Y "$hb" 2>/dev/null \
                  || echo 0)
    else
        last_epoch=$(stat -f%m "$hb" 2>/dev/null || stat -c%Y "$hb" 2>/dev/null || echo 0)
    fi
    now=$(date +%s)
    age=$(( now - last_epoch ))
    if (( age > threshold )); then
        local lock_dir="${REAPER_LOCK_DIR:-$(_reaper_main_repo)/.chump-locks}"
        local ambient="$lock_dir/ambient.jsonl"
        local age_min=$(( age / 60 ))
        local thr_min=$(( threshold / 60 ))
        local ts
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local msg="reaper-heartbeat-watchdog itself has not run in ${age_min}min (threshold ${thr_min}min). Last heartbeat at ${last_ts:-unknown}. Detected by ${REAPER_NAME:-unknown} cross-grade. Check launchctl list | grep dev.chump.reaper-watchdog and /tmp/chump-reaper-watchdog.err.log."
        printf 'ALERT [watchdog_silent] %s\n' "$msg" >&2
        local json
        if command -v python3 >/dev/null 2>&1; then
            json=$(python3 -c '
import json, sys
print(json.dumps({
    "event":"ALERT","kind":"watchdog_silent",
    "reaper":"watchdog","detected_by":sys.argv[1],
    "ts":sys.argv[2],"age_minutes":int(sys.argv[3]),
    "threshold_minutes":int(sys.argv[4]),"reason":sys.argv[5],
}))' "${REAPER_NAME:-unknown}" "$ts" "$age_min" "$thr_min" "$msg" 2>/dev/null || true)
        fi
        if [[ -z "$json" ]]; then
            json="{\"event\":\"ALERT\",\"kind\":\"watchdog_silent\",\"reaper\":\"watchdog\",\"detected_by\":\"${REAPER_NAME:-unknown}\",\"ts\":\"$ts\",\"age_minutes\":$age_min,\"threshold_minutes\":$thr_min}"
        fi
        mkdir -p "$lock_dir" 2>/dev/null || true
        printf '%s\n' "$json" >> "$ambient" 2>/dev/null || true
    fi
}

# reaper_finish STATUS COUNTS_JSON
# Convenience wrapper: computes elapsed time from REAPER_START_EPOCH and
# emits the run event + heartbeat for REAPER_NAME. Also performs a cheap
# cross-grade of the watchdog (INFRA-452): if the watchdog hasn't
# heartbeated recently, this reaper emits a watchdog_silent ALERT.
reaper_finish() {
    local status="${1:?reaper_finish needs status}"
    local counts="${2:-}"
    [[ -z "$counts" ]] && counts='{}'
    local now elapsed
    now="$(date +%s)"
    elapsed=$(( now - ${REAPER_START_EPOCH:-$now} ))
    reaper_emit_run "${REAPER_NAME:-unknown}" "$status" "$counts" "$elapsed"
    reaper_grade_watchdog
}
