#!/usr/bin/env bash
# scripts/coord/shared-target-cache-reaper.sh — RESILIENT-1045
#
# Proactive, cap-based reaper for the shared cargo build cache
# (~/.cargo/chump-shared-target). Before this existed, the ONLY code path
# that ever touched this directory was disk-critical-reactor.sh's
# quiesce_and_reclaim (RESILIENT-273) — a reactive, tier-4-only, nuclear
# reclaim that halts the whole fleet (AUTONOMY_LEVEL=0), boots out deploy
# daemons, and requires an explicit opt-in
# (CHUMP_DISK_REACTOR_QUIESCE_EXECUTE=1) before it will delete anything (it
# defaults to dry-run). Between disk-critical events the shared target cache
# just grows — on a small-volume node (e.g. a 2-core brain box) that means it
# walks the disk toward the 96%-full wedge with nothing routine keeping it
# under control.
#
# This reaper is a routine prune, not an emergency response: no daemon
# killing, no AUTONOMY_LEVEL halt, no operator page. It is safe to run on
# every disk-pressure-reaper tick (wired in below the tier ladder) or
# standalone via cron/systemd/launchd. It only acts when BOTH hold:
#   1. the shared target is over CHUMP_SHARED_TARGET_CAP_GB (default 50GB)
#   2. it is idle: no live rustc/cargo build process AND no file inside has
#      been modified in the last CHUMP_SHARED_TARGET_IDLE_MIN minutes
#      (default 15) — the same "never delete while a build holds the dir"
#      hard guard the reactor uses, just without the fleet-wide halt dance.
#
# Usage:
#   shared-target-cache-reaper.sh              # dry-run
#   shared-target-cache-reaper.sh --execute    # actually delete
#
# Env:
#   CHUMP_SHARED_TARGET               dir to watch (default ~/.cargo/chump-shared-target)
#   CHUMP_SHARED_TARGET_CAP_GB        cap in GB before reap is considered (default 50)
#   CHUMP_SHARED_TARGET_IDLE_MIN      minutes of no writes required to call it idle (default 15)
#   CHUMP_SHARED_TARGET_GB_OVERRIDE   test hook: force the "apparent size" reading
#   CHUMP_SHARED_TARGET_HOT_OVERRIDE  test hook: force hot(1)/idle(0) without real processes
#   CHUMP_AMBIENT_LOG                 ambient.jsonl path (default $CHUMP_REPO/.chump-locks/ambient.jsonl)

set -uo pipefail

SHARED_TARGET="${CHUMP_SHARED_TARGET:-$HOME/.cargo/chump-shared-target}"
CAP_GB="${CHUMP_SHARED_TARGET_CAP_GB:-50}"
IDLE_MIN="${CHUMP_SHARED_TARGET_IDLE_MIN:-15}"
REPO_ROOT="${CHUMP_REPO:-${CHUMP_HOME:-$(pwd)}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

DRY_RUN=1
[[ "${1:-}" == "--execute" ]] && DRY_RUN=0

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit() {
  local dir; dir="$(dirname "$AMBIENT")"
  [[ -d "$dir" ]] || return 0
  printf '{"ts":"%s",%s}\n' "$(ts)" "$1" >> "$AMBIENT" 2>/dev/null || true
}

# Apparent size in GB (test override so CI doesn't need a real multi-GB dir).
target_gb() {
  if [[ -n "${CHUMP_SHARED_TARGET_GB_OVERRIDE:-}" ]]; then
    echo "${CHUMP_SHARED_TARGET_GB_OVERRIDE}"; return 0
  fi
  [[ -d "$SHARED_TARGET" ]] || { echo 0; return 0; }
  du -sg "$SHARED_TARGET" 2>/dev/null | awk '{print $1}' || echo 0
}

# Hard guard: never reap while a build is live or was recently active.
is_hot() {
  if [[ -n "${CHUMP_SHARED_TARGET_HOT_OVERRIDE:-}" ]]; then
    [[ "${CHUMP_SHARED_TARGET_HOT_OVERRIDE}" == "1" ]] && return 0 || return 1
  fi
  if pgrep -f 'rustc|cargo (build|test|fix|check)' >/dev/null 2>&1; then
    return 0
  fi
  [[ -d "$SHARED_TARGET" ]] || return 1
  find "$SHARED_TARGET" -mmin -"$IDLE_MIN" -print -quit 2>/dev/null | grep -q . && return 0
  return 1
}

cur_gb="$(target_gb)"; cur_gb="${cur_gb:-0}"

if (( cur_gb <= CAP_GB )); then
  echo "[shared-target-cache-reaper] ${SHARED_TARGET} is ${cur_gb}GB <= ${CAP_GB}GB cap — nothing to do"
  exit 0
fi

if is_hot; then
  echo "[shared-target-cache-reaper] ${SHARED_TARGET} is ${cur_gb}GB > ${CAP_GB}GB cap but HOT (active build or recent write within ${IDLE_MIN}m) — skipping this tick"
  emit "\"kind\":\"shared_target_cache_reap_skipped_hot\",\"target\":\"$SHARED_TARGET\",\"target_gb\":$cur_gb,\"cap_gb\":$CAP_GB"
  exit 0
fi

if (( DRY_RUN == 1 )); then
  echo "[shared-target-cache-reaper] DRY-RUN: would reap ${SHARED_TARGET} (${cur_gb}GB > ${CAP_GB}GB cap, idle) — re-run with --execute"
  emit "\"kind\":\"shared_target_cache_reap_dryrun\",\"target\":\"$SHARED_TARGET\",\"target_gb\":$cur_gb,\"cap_gb\":$CAP_GB"
  exit 0
fi

rm -rf "${SHARED_TARGET:?}" 2>/dev/null || true
echo "[shared-target-cache-reaper] reaped ${SHARED_TARGET} (~${cur_gb}GB freed)"
emit "\"kind\":\"shared_target_cache_reaped\",\"target\":\"$SHARED_TARGET\",\"freed_gb_approx\":$cur_gb,\"cap_gb\":$CAP_GB"
