#!/usr/bin/env bash
# node-orchestrator.sh — the OS's resource-aware self-orchestration loop (RESILIENT-318 / DISK_AWARE_FLEET).
#
# Makes a node HARDWARE-AWARE and self-managing so sizing workers + placing storage
# is the OS's job, not a hand-op. One control loop: SENSE -> DECIDE -> ACT.
#   SENSE  — cores, load, RAM-free, disk-free per mounted volume -> resource-inventory.json
#   HEAL   — ensure the housekeeping organs (reapers + disk-monitor) are running; restart if down
#   SCALE  — worker pool tracks capacity: target = clamp(1 .. cores-1) by load + free RAM, with hysteresis
#   PLACE  — under sustained disk pressure, relocate heavy churn (cargo) to the largest-free volume
#            GRACEFULLY: background rsync (fleet stays up) -> atomic symlink swap -> validate.
#            Foreground mv is BANNED (it wedged the fleet 50min on 2026-08-19, unkillable D-state).
#            Auto-execute is OFF by default (CHUMP_ORCH_AUTOPLACE=1 to arm) — senses+recommends until proven.
#
# Host-agnostic supervisor calls: systemctl (Linux) — runit/launchd variants TODO via svc_* shims.
# Tracked in-repo so `chump-node-install.sh` installs it on EVERY owned node (COTG).
set -uo pipefail

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
REPO="${CHUMP_REPO_ROOT:-$HOME/Projects/chump}"
INV="$STATE_DIR/resource-inventory.json"
INTERVAL="${CHUMP_ORCH_INTERVAL:-120}"
AUTOPLACE="${CHUMP_ORCH_AUTOPLACE:-0}"          # 0 = sense+recommend only; 1 = graceful auto-relocate
WORKER_UNIT="${CHUMP_ORCH_WORKER_UNIT:-chump-cj-worker}"   # worker@1 is this; worker@N are extras
WORKER_MAX="${CHUMP_ORCH_WORKER_MAX:-0}"        # 0 = auto (cores-1)
SCALE_UP_LOAD="${CHUMP_ORCH_SCALE_UP_LOAD:-70}"   # per-core load% below which we may scale up
SCALE_DN_LOAD="${CHUMP_ORCH_SCALE_DN_LOAD:-140}"  # per-core load% above which we scale down
DISK_PLACE_PCT="${CHUMP_ORCH_DISK_PLACE_PCT:-90}" # root%>= this triggers placement consideration
HOUSEKEEPING="chump-rot-reaper.timer chump-worktree-reaper.timer chump-cj-disk-monitor.service"
mkdir -p "$STATE_DIR"
log(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

sense() {
  CORES=$(nproc)
  LOAD1=$(awk '{print $1}' /proc/loadavg)
  LOADPCT=$(awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{printf "%d", (l/c)*100}')
  RAM_AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
  ROOT_PCT=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
  # per-volume free (largest-free non-root, non-boot volume for placement targets)
  BEST_VOL=$(df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR>1 && $6!~"/boot" && $6!="/" {print $4, $6}' | sort -rn | head -1)
  BEST_VOL_FREE_KB=$(echo "$BEST_VOL" | awk '{print $1}')
  BEST_VOL_MNT=$(echo "$BEST_VOL" | awk '{print $2}')
  WORKERS_UP=$(systemctl list-units "${WORKER_UNIT}*" 'chump-cj-worker2*' --state=active --no-legend 2>/dev/null | grep -c "\.service")
  printf '{"ts":"%s","cores":%d,"load1":%s,"load_pct":%d,"ram_avail_mb":%d,"root_pct":%d,"best_vol":"%s","best_vol_free_gb":%d,"workers_up":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CORES" "$LOAD1" "$LOADPCT" "$RAM_AVAIL_MB" "$ROOT_PCT" "${BEST_VOL_MNT:-none}" "$((${BEST_VOL_FREE_KB:-0}/1024/1024))" "$WORKERS_UP" > "$INV"
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
  elif [ "$LOADPCT" -gt "$SCALE_DN_LOAD" ] && [ "$WORKERS_UP" -gt 1 ]; then
    target=$((WORKERS_UP-1)); log "SCALE: overloaded (load ${LOADPCT}%/core) -> $WORKERS_UP->$target"
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

place() {
  [ "${ROOT_PCT:-0}" -lt "$DISK_PLACE_PCT" ] && return 0
  local cargo="$HOME/.cargo"
  if [ -L "$cargo" ]; then log "PLACE: root ${ROOT_PCT}% but cargo already relocated -> $(readlink "$cargo"); nothing to move"; return 0; fi
  if [ -z "${BEST_VOL_MNT:-}" ] || [ "$BEST_VOL_MNT" = none ] || [ "$((${BEST_VOL_FREE_KB:-0}/1024/1024))" -lt 25 ]; then
    log "PLACE: root ${ROOT_PCT}% but no volume with >=25G free to hold cargo — ALERT operator"; return 0
  fi
  if [ "$AUTOPLACE" != 1 ]; then
    log "PLACE: RECOMMEND relocate ~/.cargo -> $BEST_VOL_MNT/cargo (root ${ROOT_PCT}%, target has $((BEST_VOL_FREE_KB/1024/1024))G). Auto-place OFF (set CHUMP_ORCH_AUTOPLACE=1 to arm)."; return 0
  fi
  # GRACEFUL: rsync while fleet runs, then atomic symlink swap (NEVER foreground mv)
  local lock="$STATE_DIR/.orch-place.lock"; [ -e "$lock" ] && { log "PLACE: relocation already in progress"; return 0; }
  : > "$lock"; local dst="$BEST_VOL_MNT/cargo"
  log "PLACE: graceful relocate ~/.cargo -> $dst (rsync live)"
  rsync -a --delete "$cargo/" "$dst/" 2>/dev/null && rsync -a --delete "$cargo/" "$dst/" 2>/dev/null   # 2 passes: bulk + delta
  if [ -d "$dst/registry" ]; then
    mv "$cargo" "$cargo.pre-orch-$(date -u +%s)" && ln -s "$dst" "$cargo" && log "PLACE: swapped -> $dst; validating"
    ( export PATH="$cargo/bin:$PATH"; cargo --version >/dev/null 2>&1 ) && { rm -rf "$cargo".pre-orch-* & log "PLACE: OK, old copy reaping in background"; } || log "PLACE: validation FAILED — investigate (old copy kept at $cargo.pre-orch-*)"
  else log "PLACE: rsync incomplete (no registry at $dst) — aborted, no swap"; fi
  rm -f "$lock"
}

log "node-orchestrator up (interval ${INTERVAL}s, autoplace=$AUTOPLACE)"
while true; do
  sense
  heal
  scale
  place
  sleep "$INTERVAL"
done
