#!/usr/bin/env bash
# disk-check.sh — INFRA-975
#
# Disk-pressure gates for chump claim + worker. The fleet creates ~5-9 GB
# linked worktrees (each one carries its own cargo target/), so a multi-
# hour run with parallel claims can fill /private/tmp easily. We learned
# this the hard way 2026-05-13: 60+ GB of stale target/ dirs broke every
# install attempt for hours.
#
# Sourceable. Two public functions:
#
#   chump_disk_free_gb [path]
#       Echo integer GB free on the filesystem hosting `path` (default: .).
#       Empty output on probe failure.
#
#   chump_disk_check_or_abort
#       Used by gap-claim.sh. If free < CHUMP_DISK_LOW_GB (default 5),
#       emit kind=claim_aborted_disk_full and `exit 1`. Honors
#       CHUMP_DISK_CHECK_DISABLE=1 escape hatch.
#
#   chump_disk_check_pause_worker
#       Used by worker.sh. If free < CHUMP_DISK_CRITICAL_GB (default 1),
#       emit kind=fleet_paused_disk_critical and return 1 (caller pauses).
#       Returns 0 when fine. Honors CHUMP_DISK_CHECK_DISABLE=1.
#
# Env:
#   CHUMP_DISK_LOW_GB         claim-abort threshold (default 5)
#   CHUMP_DISK_CRITICAL_GB    worker-pause threshold (default 1)
#   CHUMP_DISK_CHECK_DISABLE  =1 short-circuits all checks (escape hatch)
#   CHUMP_DISK_CHECK_PATH     filesystem to probe (default = cwd)
#   CHUMP_AMBIENT_LOG         ambient.jsonl path (default .chump-locks/ambient.jsonl)

# Idempotent guard so multiple sources don't re-define.
[[ "${_CHUMP_DISK_CHECK_LOADED:-0}" == "1" ]] || {
_CHUMP_DISK_CHECK_LOADED=1

_dc_log() { printf '[disk-check] %s\n' "$*" >&2; }

# Echo integer GB free on $1's filesystem.
chump_disk_free_gb() {
  local path="${1:-${CHUMP_DISK_CHECK_PATH:-.}}"
  # df -k → 1KB blocks. Available is column 4 on macOS + Linux.
  local kb
  kb="$(df -k "$path" 2>/dev/null | awk 'NR==2 { print $4 }')"
  [[ -z "$kb" || ! "$kb" =~ ^[0-9]+$ ]] && return 0
  printf '%d' $(( kb / 1024 / 1024 ))
}

_dc_emit() {
  local kind="$1"; shift
  local amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
  mkdir -p "$(dirname "$amb")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"%s",%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$*" \
    >> "$amb" 2>/dev/null || true
}

# gap-claim.sh pre-check. Exits 1 when free < threshold.
chump_disk_check_or_abort() {
  [[ "${CHUMP_DISK_CHECK_DISABLE:-0}" == "1" ]] && return 0
  local threshold="${CHUMP_DISK_LOW_GB:-5}"
  local free; free=$(chump_disk_free_gb)
  [[ -z "$free" ]] && return 0  # probe failed; fail open

  if [[ "$free" -lt "$threshold" ]]; then
    _dc_log "ABORT: disk free ${free}GB < threshold ${threshold}GB"
    _dc_log "       Re-run after pruning worktrees / cargo target dirs."
    _dc_log "       Bypass: CHUMP_DISK_CHECK_DISABLE=1 (e.g. when you know you have"
    _dc_log "       just-freed space about to come through df)."
    _dc_emit "claim_aborted_disk_full" \
      '"free_gb":'"$free"',"threshold_gb":'"$threshold"',"path":"'"${CHUMP_DISK_CHECK_PATH:-$(pwd)}"'"'
    exit 1
  fi
  return 0
}

# worker.sh pre-cycle check. Returns 1 when caller should pause.
chump_disk_check_pause_worker() {
  [[ "${CHUMP_DISK_CHECK_DISABLE:-0}" == "1" ]] && return 0
  local threshold="${CHUMP_DISK_CRITICAL_GB:-1}"
  local free; free=$(chump_disk_free_gb)
  [[ -z "$free" ]] && return 0

  if [[ "$free" -lt "$threshold" ]]; then
    _dc_log "PAUSE: disk free ${free}GB < critical ${threshold}GB"
    _dc_emit "fleet_paused_disk_critical" \
      '"free_gb":'"$free"',"threshold_gb":'"$threshold"',"path":"'"${CHUMP_DISK_CHECK_PATH:-$(pwd)}"'"'
    return 1
  fi
  return 0
}

}  # end idempotent guard
