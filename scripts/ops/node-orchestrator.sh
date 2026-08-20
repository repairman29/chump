#!/usr/bin/env bash
# node-orchestrator.sh — the OS's resource-aware self-orchestration loop (RESILIENT-318 / DISK_AWARE_FLEET).
#
# Makes a node HARDWARE-AWARE and self-managing so sizing workers + placing storage
# is the OS's job, not a hand-op. One control loop: SENSE -> DECIDE -> ACT.
#   SENSE  — cores, load, RAM-free, disk-free per mounted volume + /tmp fstype/pct -> resource-inventory.json
#   HEAL   — ensure the housekeeping organs (reapers + disk-monitor) are running; restart if down
#   SCALE  — worker pool tracks capacity: target = clamp(1 .. cores-1) by load + free RAM, with hysteresis
#   PLACE  — under sustained root-disk pressure, relocate heavy churn (cargo, .claude/worktrees) to the
#            largest-free volume GRACEFULLY: background rsync (fleet stays up) -> atomic symlink swap ->
#            validate -> reap old copy in background. Foreground mv is BANNED (it wedged the fleet 50min
#            on 2026-08-19, unkillable D-state). Independently, sustained tmpfs pressure on /tmp routes
#            TMPDIR to a data volume via the shared worker env file (CHUMP_ORCH_ENV_FILE) — takes effect
#            on next worker restart, no foreground disruption.
#            Auto-execute is ON by default (RESILIENT-322, proven via forced-pressure test on CJ) — set
#            CHUMP_ORCH_AUTOPLACE=0 to fall back to sense+recommend only.
#
# Host-agnostic supervisor calls: systemctl (Linux) — runit/launchd variants TODO via svc_* shims.
# Tracked in-repo so `chump-node-install.sh` installs it on EVERY owned node (COTG).
set -uo pipefail

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
REPO="${CHUMP_REPO_ROOT:-$HOME/Projects/chump}"
INV="$STATE_DIR/resource-inventory.json"
INTERVAL="${CHUMP_ORCH_INTERVAL:-120}"
AUTOPLACE="${CHUMP_ORCH_AUTOPLACE:-1}"          # 0 = sense+recommend only; 1 = graceful auto-relocate (default ON, RESILIENT-322)
WORKER_UNIT="${CHUMP_ORCH_WORKER_UNIT:-chump-cj-worker}"   # worker@1 is this; worker@N are extras
WORKER_MAX="${CHUMP_ORCH_WORKER_MAX:-0}"        # 0 = auto (cores-1)
SCALE_UP_LOAD="${CHUMP_ORCH_SCALE_UP_LOAD:-70}"   # per-core load% below which we may scale up
SCALE_DN_LOAD="${CHUMP_ORCH_SCALE_DN_LOAD:-300}"  # per-core load% = GENUINE thrash (build fleets peg cores; busy≠oversubscribed)
RAM_SHED_MB="${CHUMP_ORCH_RAM_SHED_MB:-800}"      # RAM-avail floor: real shed signal is memory pressure, not busy CPU
DISK_PLACE_PCT="${CHUMP_ORCH_DISK_PLACE_PCT:-90}" # root%/tmp%>= this triggers placement consideration
HOUSEKEEPING="${CHUMP_ORCH_HOUSEKEEPING:-chump-rot-reaper.service chump-worktree-reaper.service chump-disk-monitor.service}"
ORCH_ENV_FILE="${CHUMP_ORCH_ENV_FILE:-$STATE_DIR/cj.env}"   # shared worker env file; TMPDIR route lands here
mkdir -p "$STATE_DIR"
log(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

sense() {
  CORES=$(nproc)
  LOAD1=$(awk '{print $1}' /proc/loadavg)
  LOADPCT=$(awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{printf "%d", (l/c)*100}')
  RAM_AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
  ROOT_PCT=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
  # per-volume free (largest-free non-root, non-boot volume for placement targets)
  # placement targets: real data volumes only — exclude vfat (printer/boot) which can't hold cargo symlinks/perms
  BEST_VOL=$(df -P -x tmpfs -x devtmpfs -x vfat 2>/dev/null | awk 'NR>1 && $6!~"/boot" && $6!~"/print" && $6!="/" {print $4, $6}' | sort -rn | head -1)
  BEST_VOL_FREE_KB=$(echo "$BEST_VOL" | awk '{print $1}')
  BEST_VOL_MNT=$(echo "$BEST_VOL" | awk '{print $2}')
  # /tmp pressure: only tmpfs /tmp is quota-bounded by RAM — a full tmpfs /tmp breaks builds independent of root%
  TMP_FSTYPE=$(awk '$2=="/tmp"{print $3; exit}' /proc/mounts 2>/dev/null || true)
  TMP_PCT=$(df -P /tmp 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  WORKERS_UP=$(systemctl list-units "${WORKER_UNIT}*" 'chump-cj-worker2*' --state=active --no-legend 2>/dev/null | grep -c "\.service")
  printf '{"ts":"%s","cores":%d,"load1":%s,"load_pct":%d,"ram_avail_mb":%d,"root_pct":%d,"best_vol":"%s","best_vol_free_gb":%d,"tmp_fstype":"%s","tmp_pct":%d,"workers_up":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CORES" "$LOAD1" "$LOADPCT" "$RAM_AVAIL_MB" "$ROOT_PCT" "${BEST_VOL_MNT:-none}" "$((${BEST_VOL_FREE_KB:-0}/1024/1024))" "${TMP_FSTYPE:-unknown}" "${TMP_PCT:-0}" "$WORKERS_UP" > "$INV"
}

heal() {
  for u in $HOUSEKEEPING; do
    systemctl is-active "$u" >/dev/null 2>&1 || { log "HEAL: $u down -> restart"; sudo systemctl restart "$u" 2>/dev/null || true; }
  done
}

scale() {
  local max=$WORKER_MAX; [ "$max" = 0 ] && max=$((CORES-1)); [ "$max" -lt 1 ] && max=1
  local target=$WORKERS_UP
  # scale up only with idle CPU AND >=1.5G free RAM per new worker
  if [ "$LOADPCT" -lt "$SCALE_UP_LOAD" ] && [ "$RAM_AVAIL_MB" -gt 1500 ] && [ "$WORKERS_UP" -lt "$max" ]; then
    target=$((WORKERS_UP+1)); log "SCALE: idle (load ${LOADPCT}%/core, RAM ${RAM_AVAIL_MB}MB) -> $WORKERS_UP->$target (max $max)"
  elif { [ "$RAM_AVAIL_MB" -lt "$RAM_SHED_MB" ] || [ "$LOADPCT" -gt "$SCALE_DN_LOAD" ]; } && [ "$WORKERS_UP" -gt 1 ]; then
    # shed only on REAL pressure: low RAM (OOM risk) or genuine thrash — NOT normal build-busy CPU
    target=$((WORKERS_UP-1)); log "SCALE: shed on pressure (RAM ${RAM_AVAIL_MB}MB<${RAM_SHED_MB} or load ${LOADPCT}%/core>${SCALE_DN_LOAD}) -> $WORKERS_UP->$target"
  fi
  # hysteresis: require the same decision twice before acting
  local mark="$STATE_DIR/.orch-scale-intent"
  local prev; prev=$(cat "$mark" 2>/dev/null || echo "$WORKERS_UP")
  echo "$target" > "$mark"
  [ "$target" = "$WORKERS_UP" ] && return 0
  [ "$target" != "$prev" ] && { log "SCALE: intent $target not yet confirmed (was $prev) — waiting one cycle"; return 0; }
  # act: worker@N units are chump-cj-worker2, worker3... (N=2 is the existing extra)
  if [ "$target" -gt "$WORKERS_UP" ]; then
    local n=$((target)); sudo systemctl start "chump-cj-worker${n}" 2>/dev/null && log "SCALE: started chump-cj-worker${n}" || log "SCALE: chump-cj-worker${n} not installed (need unit) — cannot scale up past installed workers"
  else
    local n=$((WORKERS_UP)); sudo systemctl stop "chump-cj-worker${n}" 2>/dev/null && log "SCALE: stopped chump-cj-worker${n}"
  fi
}

# place_cargo — relocate ~/.cargo to the largest-free data volume. GRACEFUL: rsync live (fleet keeps
# building against the old path until the swap instant), then an atomic rename+symlink (not a copy —
# O(1), not the banned foreground mv-of-23G), then validate `cargo --version` through the new path
# before reaping the old copy in the background.
place_cargo() {
  local cargo="$HOME/.cargo"
  if [ -L "$cargo" ]; then log "PLACE: root ${ROOT_PCT}% but cargo already relocated -> $(readlink "$cargo"); nothing to move"; return 0; fi
  local dst="$BEST_VOL_MNT/cargo"
  if [ "$AUTOPLACE" != 1 ]; then
    log "PLACE: RECOMMEND relocate ~/.cargo -> $dst (root ${ROOT_PCT}%, target has $((BEST_VOL_FREE_KB/1024/1024))G). Auto-place OFF (set CHUMP_ORCH_AUTOPLACE=1 to arm)."; return 0
  fi
  local lock="$STATE_DIR/.orch-place-cargo.lock"; [ -e "$lock" ] && { log "PLACE: cargo relocation already in progress"; return 0; }
  : > "$lock"
  log "PLACE: graceful relocate ~/.cargo -> $dst (rsync live)"
  mkdir -p "$dst"
  rsync -a --delete "$cargo/" "$dst/" 2>/dev/null && rsync -a --delete "$cargo/" "$dst/" 2>/dev/null   # 2 passes: bulk + delta
  if [ -d "$dst/registry" ] || [ -d "$dst/bin" ]; then
    mv "$cargo" "$cargo.pre-orch-$(date -u +%s)" && ln -s "$dst" "$cargo" && log "PLACE: cargo swapped -> $dst; validating"
    ( export PATH="$cargo/bin:$PATH"; cargo --version >/dev/null 2>&1 ) && { rm -rf "$cargo".pre-orch-* & log "PLACE: cargo OK, old copy reaping in background"; } || log "PLACE: cargo validation FAILED — investigate (old copy kept at $cargo.pre-orch-*)"
  else log "PLACE: cargo rsync incomplete (no registry/bin at $dst) — aborted, no swap"; fi
  rm -f "$lock"
}

# place_worktrees — same graceful rsync+atomic-swap pattern for .claude/worktrees. The symlink swap
# preserves every worktree's absolute path (git's .git/worktrees/<name>/gitdir back-references still
# resolve through the symlink), so no gitdir surgery is needed — validate with `git worktree list`.
place_worktrees() {
  local wtdir="$REPO/.claude/worktrees"
  [ -d "$wtdir" ] || { log "PLACE: no $wtdir on this node — nothing to move"; return 0; }
  if [ -L "$wtdir" ]; then log "PLACE: root ${ROOT_PCT}% but worktrees already relocated -> $(readlink "$wtdir"); nothing to move"; return 0; fi
  local dst="$BEST_VOL_MNT/worktrees"
  if [ "$AUTOPLACE" != 1 ]; then
    log "PLACE: RECOMMEND relocate $wtdir -> $dst (root ${ROOT_PCT}%, target has $((BEST_VOL_FREE_KB/1024/1024))G). Auto-place OFF (set CHUMP_ORCH_AUTOPLACE=1 to arm)."; return 0
  fi
  local lock="$STATE_DIR/.orch-place-worktrees.lock"; [ -e "$lock" ] && { log "PLACE: worktrees relocation already in progress"; return 0; }
  : > "$lock"
  log "PLACE: graceful relocate $wtdir -> $dst (rsync live, fleet stays up)"
  mkdir -p "$dst"
  rsync -a --delete "$wtdir/" "$dst/" 2>/dev/null && rsync -a --delete "$wtdir/" "$dst/" 2>/dev/null   # 2 passes: bulk + delta
  mv "$wtdir" "$wtdir.pre-orch-$(date -u +%s)" && ln -s "$dst" "$wtdir" && log "PLACE: worktrees swapped -> $dst; validating"
  ( cd "$REPO" && git worktree list >/dev/null 2>&1 ) && { rm -rf "$wtdir".pre-orch-* & log "PLACE: worktrees OK, old copy reaping in background"; } || log "PLACE: worktrees validation FAILED — investigate (old copy kept at $wtdir.pre-orch-*)"
  rm -f "$lock"
}

# place_tmpdir — independent trigger from root-disk placement: a tmpfs /tmp is RAM-bounded, so it can
# fill and break builds even when root% is fine. Route TMPDIR to a data volume via the shared worker
# env file (sourced by cj-worker-run.sh style launchers); takes effect on next worker restart, so this
# never disrupts an in-flight build.
place_tmpdir() {
  [ "${TMP_FSTYPE:-}" = tmpfs ] || return 0
  [ "${TMP_PCT:-0}" -lt "$DISK_PLACE_PCT" ] && return 0
  if [ -z "${BEST_VOL_MNT:-}" ] || [ "$BEST_VOL_MNT" = none ]; then
    log "PLACE: /tmp tmpfs at ${TMP_PCT}% but no data volume available for TMPDIR route — ALERT operator"; return 0
  fi
  local dst="$BEST_VOL_MNT/tmp"
  if [ "$AUTOPLACE" != 1 ]; then
    log "PLACE: RECOMMEND route TMPDIR -> $dst (/tmp tmpfs ${TMP_PCT}%). Auto-place OFF (set CHUMP_ORCH_AUTOPLACE=1 to arm)."; return 0
  fi
  mkdir -p "$dst" 2>/dev/null
  if grep -q "^export TMPDIR=$dst\$" "$ORCH_ENV_FILE" 2>/dev/null; then
    return 0   # already routed to this target — nothing to do
  elif grep -q "^export TMPDIR=" "$ORCH_ENV_FILE" 2>/dev/null; then
    sed -i "s#^export TMPDIR=.*#export TMPDIR=$dst#" "$ORCH_ENV_FILE"
  else
    printf 'export TMPDIR=%s\n' "$dst" >> "$ORCH_ENV_FILE"
  fi
  log "PLACE: /tmp tmpfs pressure (${TMP_PCT}%) -> routed TMPDIR=$dst in $ORCH_ENV_FILE (takes effect on next worker restart)"
}

place() {
  if [ "${ROOT_PCT:-0}" -ge "$DISK_PLACE_PCT" ]; then
    if [ -z "${BEST_VOL_MNT:-}" ] || [ "$BEST_VOL_MNT" = none ] || [ "$((${BEST_VOL_FREE_KB:-0}/1024/1024))" -lt 25 ]; then
      log "PLACE: root ${ROOT_PCT}% but no volume with >=25G free to hold cargo/worktrees — ALERT operator"
    else
      place_cargo
      place_worktrees
    fi
  fi
  place_tmpdir
}

log "node-orchestrator up (interval ${INTERVAL}s, autoplace=$AUTOPLACE)"
# CHUMP_ORCH_TEST_SOURCE=1 lets tests `source` this file for the sense/place/scale functions without
# entering the daemon loop (scripts/ci/test-node-orchestrator-place.sh).
if [ "${CHUMP_ORCH_TEST_SOURCE:-0}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi
while true; do
  sense
  heal
  scale
  place
  sleep "$INTERVAL"
done
