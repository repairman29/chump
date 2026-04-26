#!/usr/bin/env bash
# run-overnight-research.sh — execute every job in scripts/overnight/ in
# alphabetical order. Designed for launchd / cron (default 02:00 local).
#
# Why this exists: research churn (eval sweeps, A/B studies, ablations) was
# eating daytime CPU/RAM and competing with the dispatcher's coding agents.
# Per the 2026-04-26 directive, that work is moved to overnight via this
# wrapper + scripts/install-overnight-research-launchd.sh.
#
# Convention:
#   scripts/overnight/*.sh       — executable jobs run in lexicographic order
#   scripts/overnight/*.disabled — ignored (rename to .sh to enable)
#
# Each job runs from REPO root with a per-job timeout. Failures are logged
# but do not abort sibling jobs.
#
# Lock: .chump/overnight.lock prevents overlap if a previous run hasn't
# finished. If the lock is older than $STALE_LOCK_HOURS, it is overridden.
#
# Logs:
#   /tmp/chump-overnight-research.out.log  (stdout/stderr)
#   .chump/overnight/<UTC-timestamp>.log   (per-run archive)
#
# Ambient: emits start / done / error events to .chump-locks/ambient.jsonl
# so daytime agents can see what ran while they were asleep.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

OVERNIGHT_DIR="$REPO/scripts/overnight"
LOG_DIR="$REPO/.chump/overnight"
LOCK="$REPO/.chump/overnight.lock"
PER_JOB_TIMEOUT_SECS="${CHUMP_OVERNIGHT_JOB_TIMEOUT_SECS:-3600}"
STALE_LOCK_HOURS="${CHUMP_OVERNIGHT_STALE_LOCK_HOURS:-12}"

mkdir -p "$LOG_DIR" "$(dirname "$LOCK")"
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_LOG="$LOG_DIR/$RUN_ID.log"

log() { echo "[$(ts)] $*" | tee -a "$RUN_LOG"; }

emit_ambient() {
  local kind="$1"; shift
  local payload="$*"
  local ambient="$REPO/.chump-locks/ambient.jsonl"
  mkdir -p "$(dirname "$ambient")"
  printf '{"ts":"%s","kind":"%s","source":"overnight-research","run_id":"%s",%s}\n' \
    "$(ts)" "$kind" "$RUN_ID" "$payload" >>"$ambient" 2>/dev/null || true
}

# --- lock guard ---
if [[ -f "$LOCK" ]]; then
  lock_age_hours=$(( ( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0) ) / 3600 ))
  if (( lock_age_hours < STALE_LOCK_HOURS )); then
    log "lock present (${lock_age_hours}h old, threshold ${STALE_LOCK_HOURS}h) — exiting"
    emit_ambient "overnight_skip" "\"reason\":\"lock_held\",\"age_hours\":$lock_age_hours"
    exit 0
  fi
  log "stale lock (${lock_age_hours}h) — overriding"
fi
echo "$$" >"$LOCK"
trap 'rm -f "$LOCK"' EXIT

# --- discovery ---
if [[ ! -d "$OVERNIGHT_DIR" ]]; then
  log "no overnight directory at $OVERNIGHT_DIR — nothing to do"
  exit 0
fi

shopt -s nullglob
JOBS=("$OVERNIGHT_DIR"/*.sh)
shopt -u nullglob

if (( ${#JOBS[@]} == 0 )); then
  log "no jobs in $OVERNIGHT_DIR — nothing to do"
  emit_ambient "overnight_skip" "\"reason\":\"no_jobs\""
  exit 0
fi

log "starting run_id=$RUN_ID — ${#JOBS[@]} job(s)"
emit_ambient "overnight_start" "\"job_count\":${#JOBS[@]}"

# --- execute ---
PASS=0
FAIL=0
for job in "${JOBS[@]}"; do
  name="$(basename "$job")"
  if [[ ! -x "$job" ]]; then
    log "SKIP $name (not executable)"
    continue
  fi
  log "RUN  $name (timeout ${PER_JOB_TIMEOUT_SECS}s)"
  job_start=$(date +%s)
  if timeout "$PER_JOB_TIMEOUT_SECS" "$job" >>"$RUN_LOG" 2>&1; then
    elapsed=$(( $(date +%s) - job_start ))
    log "PASS $name (${elapsed}s)"
    PASS=$((PASS + 1))
  else
    rc=$?
    elapsed=$(( $(date +%s) - job_start ))
    log "FAIL $name rc=$rc (${elapsed}s)"
    FAIL=$((FAIL + 1))
    emit_ambient "overnight_job_fail" "\"job\":\"$name\",\"rc\":$rc,\"elapsed_s\":$elapsed"
  fi
done

log "done — pass=$PASS fail=$FAIL"
emit_ambient "overnight_done" "\"pass\":$PASS,\"fail\":$FAIL"
exit 0
