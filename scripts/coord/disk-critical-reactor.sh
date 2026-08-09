#!/usr/bin/env bash
# scripts/coord/disk-critical-reactor.sh — INFRA-2304
#
# Reactive consumer of disk_critical events. Until this exists, disk_critical
# ALERTs sit in ambient.jsonl until the next 15-min disk-pressure-reaper cron
# tick — leaving a 0-15 min window where the fleet is at risk and nothing
# automated reacts. This reactor closes that gap.
#
# Behavior:
#   1. Tail .chump-locks/ambient.jsonl (follow rotations via tail -F)
#   2. On each disk_critical event:
#        - Apply debounce (60s min between fires, per-process state)
#        - Read current free GB via df
#        - Compute escalated tier = (current_tier + 1), bounded by 4
#        - Invoke disk-pressure-reaper.sh --execute --tier <escalated>
#        - If post-reap free GB is still <5%, call operator-recall.sh
#          --condition DISK_CRITICAL --reason "..."
#        - Emit kind=disk_critical_reactor_fired with metrics
#   3. Run as a long-lived launchd KeepAlive process
#
# Env:
#   CHUMP_REPO                              repo root (default /Users/jeffadkins/Projects/Chump)
#   CHUMP_DISK_REACTOR_DEBOUNCE_SECS        per-event debounce (default 60)
#   CHUMP_DISK_REACTOR_PAGE_THRESHOLD_PCT   page operator if post-reap free% below (default 5)

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-${CHUMP_HOME:-/Users/jeffadkins/Projects/Chump}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
REAPER="$REPO_ROOT/scripts/coord/disk-pressure-reaper.sh"
RECALL="$REPO_ROOT/scripts/dispatch/operator-recall.sh"
DEBOUNCE="${CHUMP_DISK_REACTOR_DEBOUNCE_SECS:-60}"
PAGE_THRESHOLD="${CHUMP_DISK_REACTOR_PAGE_THRESHOLD_PCT:-5}"
STATE_DIR="$REPO_ROOT/.chump-locks"
LAST_FIRE_FILE="$STATE_DIR/disk-critical-reactor.last"

# RESILIENT-273: the terminal self-heal the reactor was missing. The delegated
# disk-pressure-reaper can NOT reclaim the shared cargo target while the fleet is
# building into it (its mtime/hot guard sees everything as "hot"), so at real
# disk-critical it freed 0 bytes and this reactor just paged a human (2026-08-09,
# shared target bloated to ~150GB, disk 4% free). This tier reclaims it the way a
# human had to: quiesce every writer — including the deploy daemons that IGNORE
# AUTONOMY_LEVEL and respawn cargo builds — then prune, then restore. DRY-RUN by
# default (like the integrator daemon); set CHUMP_DISK_REACTOR_QUIESCE_EXECUTE=1
# to arm. Hard guard: never deletes unless the dir is truly quiescent (0 builds).
SHARED_TARGET="${CHUMP_SHARED_TARGET:-$HOME/.cargo/chump-shared-target}"
SHARED_TARGET_CAP_GB="${CHUMP_SHARED_TARGET_CAP_GB:-50}"
QUIESCE_EXECUTE="${CHUMP_DISK_REACTOR_QUIESCE_EXECUTE:-0}"
# Daemons that keep spawning cargo builds and do NOT honor AUTONOMY_LEVEL=0.
QUIESCE_DAEMONS="${CHUMP_DISK_REACTOR_QUIESCE_DAEMONS:-com.chump.auto-deploy com.chump.refresh-runner-binary}"
QUIESCE_WAIT_S="${CHUMP_DISK_REACTOR_QUIESCE_WAIT_S:-90}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit() {
  local payload="$1"
  printf '{"ts":"%s",%s}\n' "$(ts)" "$payload" >> "$AMBIENT" 2>/dev/null || true
}

free_gb() {
  df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}' || \
  df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}'
}

free_pct() {
  df -P /System/Volumes/Data 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print 100-$5}' || echo 50
}

tier_for() {
  local gb="$1"
  if   (( gb >= 50 )); then echo 0
  elif (( gb >= 20 )); then echo 1
  elif (( gb >= 10 )); then echo 2
  elif (( gb >= 5 ));  then echo 3
  else echo 4
  fi
}

# Apparent size of the shared target in GB (test override for CI: no real 50GB dir).
shared_target_gb() {
  if [[ -n "${CHUMP_SHARED_TARGET_GB_OVERRIDE:-}" ]]; then
    echo "$CHUMP_SHARED_TARGET_GB_OVERRIDE"; return 0
  fi
  [[ -d "$SHARED_TARGET" ]] || { echo 0; return 0; }
  du -sg "$SHARED_TARGET" 2>/dev/null | awk '{print $1}' || echo 0
}

# Count live cargo/rustc build processes writing the shared target. chumpd (the
# supervisor) and this reactor's own worktree are excluded.
build_procs() {
  ps aux 2>/dev/null | grep -E 'rustc|cargo (build|test|fix)|refresh-runner' \
    | grep -v grep | grep -v 'chumpd' | grep -v 'resilient-273' | wc -l | tr -d ' '
}

restore_quiesce_daemons() {
  local uid; uid="$(id -u)"
  local lbl p
  for lbl in $QUIESCE_DAEMONS; do
    p="$HOME/Library/LaunchAgents/${lbl}.plist"
    [[ -f "$p" ]] && launchctl bootstrap "gui/$uid" "$p" 2>/dev/null || true
  done
}

# Scanner anchors for the event-registry verify rule (src/verify/rules/event_registry.rs):
# the emit() helper below escapes quotes, so these literals give the detector a
# contiguous "kind":"..." to match. Emitted for real in quiesce_and_reclaim():
#   "kind":"disk_reactor_quiesce_dryrun"
#   "kind":"disk_reactor_quiesce_started"
#   "kind":"disk_reactor_quiesce_aborted"
#   "kind":"disk_reactor_quiesce_reclaimed"
#
# RESILIENT-273: the terminal reclaim. Only fires when the shared target is over
# the hard cap. DRY-RUN unless CHUMP_DISK_REACTOR_QUIESCE_EXECUTE=1. Returns 0 if
# it reclaimed (or would in dry-run), 1 if not applicable / aborted for safety.
quiesce_and_reclaim() {
  local cur_gb; cur_gb="$(shared_target_gb)"; cur_gb="${cur_gb:-0}"
  if (( cur_gb <= SHARED_TARGET_CAP_GB )); then
    return 1  # not the shared-target-bloat failure mode; nothing to do here
  fi

  if [[ "$QUIESCE_EXECUTE" != "1" ]]; then
    emit "\"kind\":\"disk_reactor_quiesce_dryrun\",\"target\":\"$SHARED_TARGET\",\"target_gb\":$cur_gb,\"cap_gb\":$SHARED_TARGET_CAP_GB,\"note\":\"would quiesce builds+daemons and prune; set CHUMP_DISK_REACTOR_QUIESCE_EXECUTE=1 to arm\""
    echo "[disk-critical-reactor] DRY-RUN: $SHARED_TARGET is ${cur_gb}GB > ${SHARED_TARGET_CAP_GB}GB cap — would quiesce + reclaim (arm with CHUMP_DISK_REACTOR_QUIESCE_EXECUTE=1)" >&2
    return 0
  fi

  emit "\"kind\":\"disk_reactor_quiesce_started\",\"target\":\"$SHARED_TARGET\",\"target_gb\":$cur_gb,\"cap_gb\":$SHARED_TARGET_CAP_GB"
  # 1. Stop the fleet go-switch + tear down the tmux fleet.
  echo 0 > "$HOME/.chump/AUTONOMY_LEVEL" 2>/dev/null || true
  tmux kill-session -t chump-fleet 2>/dev/null || true
  # 2. Bootout the deploy daemons that ignore AUTONOMY_LEVEL and respawn builds.
  local uid; uid="$(id -u)"
  local lbl
  for lbl in $QUIESCE_DAEMONS; do launchctl bootout "gui/$uid/$lbl" 2>/dev/null || true; done
  # 3. Kill in-flight builds.
  pkill -x rustc 2>/dev/null || true
  pkill -f 'cargo build' 2>/dev/null || true
  pkill -f 'refresh-runner-binary' 2>/dev/null || true
  pkill -f 'auto-deploy.sh' 2>/dev/null || true
  # 4. Wait for true quiescence (bounded).
  local waited=0 remaining
  remaining="$(build_procs)"
  while (( remaining > 0 && waited < QUIESCE_WAIT_S )); do
    sleep 3; waited=$((waited + 3)); remaining="$(build_procs)"
  done
  # 5. HARD GUARD (RESILIENT-112): never delete while a build still holds the dir.
  if (( remaining > 0 )); then
    emit "\"kind\":\"disk_reactor_quiesce_aborted\",\"reason\":\"not_quiescent\",\"remaining_builds\":$remaining,\"waited_s\":$waited"
    restore_quiesce_daemons
    return 1
  fi
  # 6. Prune, then restore the daemons.
  rm -rf "$SHARED_TARGET" 2>/dev/null || true
  local after_gb; after_gb="$(free_gb)"; after_gb="${after_gb:-0}"
  emit "\"kind\":\"disk_reactor_quiesce_reclaimed\",\"target\":\"$SHARED_TARGET\",\"reclaimed_gb_approx\":$cur_gb,\"free_gb_after\":$after_gb"
  restore_quiesce_daemons
  return 0
}

react() {
  local now last
  now=$(date +%s)
  last=$(cat "$LAST_FIRE_FILE" 2>/dev/null || echo 0)
  if (( now - last < DEBOUNCE )); then
    return 0
  fi
  echo "$now" > "$LAST_FIRE_FILE"

  local fgb cur_tier esc_tier
  fgb=$(free_gb); fgb="${fgb:-0}"
  cur_tier=$(tier_for "$fgb")
  esc_tier=$(( cur_tier + 1 ))
  (( esc_tier > 4 )) && esc_tier=4

  emit "\"kind\":\"disk_critical_reactor_fired\",\"free_gb\":$fgb,\"current_tier\":$cur_tier,\"escalated_tier\":$esc_tier,\"trigger\":\"ambient_event\""

  if [[ -x "$REAPER" ]]; then
    "$REAPER" --execute --tier "$esc_tier" >> /tmp/chump-disk-critical-reactor.out.log 2>&1 || true
  fi

  local post_pct
  post_pct=$(free_pct)

  # RESILIENT-273: if the delegated reaper didn't recover headroom AND the shared
  # cargo target is over its hard cap, that's the bloat the reaper structurally
  # can't touch — run the terminal quiesce-prune self-heal BEFORE paging a human,
  # then re-check. Paging is the last resort, not the first (and only) response.
  if (( post_pct < PAGE_THRESHOLD )); then
    quiesce_and_reclaim || true
    post_pct=$(free_pct)
  fi

  if (( post_pct < PAGE_THRESHOLD )); then
    if [[ -x "$RECALL" ]]; then
      "$RECALL" --condition DISK_CRITICAL \
        --reason "post-reactor disk still ${post_pct}% free (<${PAGE_THRESHOLD}%); tier-${esc_tier} reap + shared-target quiesce did not recover sufficient headroom" \
        >> /tmp/chump-disk-critical-reactor.out.log 2>&1 || true
    fi
  fi
}

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  touch "$AMBIENT" 2>/dev/null || true

  echo "[disk-critical-reactor] starting; tailing $AMBIENT (debounce=${DEBOUNCE}s, page_threshold=${PAGE_THRESHOLD}%)" >&2

  tail -n 0 -F "$AMBIENT" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *'"kind":"disk_critical"'*) react ;;
    esac
  done
}

# RESILIENT-273: one-shot self-heal hook for tests + manual runs. Honors the same
# DRY-RUN default, so a bare invocation only reports.
if [[ "${1:-}" == "--quiesce-check" ]]; then
  quiesce_and_reclaim; exit $?
fi

# Allow one-shot mode for testing: emit + process a single event from stdin
if [[ "${1:-}" == "--once" ]]; then
  line="${2:-}"
  if [[ -z "$line" ]]; then
    read -r line
  fi
  case "$line" in
    *'"kind":"disk_critical"'*) react; exit 0 ;;
    *) echo "[disk-critical-reactor] --once: line does not contain disk_critical, no-op" >&2; exit 0 ;;
  esac
fi

main
