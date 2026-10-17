#!/usr/bin/env bash
# node-deadman-monitor.sh — RESILIENT-1611 (PHASE-R R6): node-level watchdog
# against admission-ceiling wedges.
#
# When load1 stays above 3x nproc for 10 minutes or MemAvailable under 5 percent
# for 10 minutes, kill the newest `claude -p` and `cargo tree` processes first,
# and if sshd stays unresponsive for 15 minutes, trigger a hardware watchdog
# reboot (systemd watchdog or kernel softdog).
#
# Usage:
#   scripts/ops/node-deadman-monitor.sh              # one pass (runs until action)
#   scripts/ops/node-deadman-monitor.sh --check      # health report only
#   scripts/ops/node-deadman-monitor.sh --dry-run    # report only, no kills/reboots
#
# Environment:
#   CHUMP_DEADMAN_DRY_RUN=1         equivalent to --dry-run
#   CHUMP_DEADMAN_CHECK_ONLY=1      equivalent to --check
#   CHUMP_DEADMAN_LOAD_MULTIPLIER   multiplier for load threshold (default: 3)
#   CHUMP_DEADMAN_MEM_THRESHOLD_PCT memory available threshold (default: 5)
#   CHUMP_DEADMAN_RISE_TIME_S       seconds to hold above threshold before action (default: 600)
#   CHUMP_DEADMAN_SSH_TIMEOUT_S     seconds of unresponsive sshd before reboot (default: 900)

set -uo pipefail

DRY_RUN="${CHUMP_DEADMAN_DRY_RUN:-0}"
CHECK_ONLY="${CHUMP_DEADMAN_CHECK_ONLY:-0}"

case "${1:-}" in
  --dry-run) DRY_RUN=1; shift 2>/dev/null || true;;
  --check) CHECK_ONLY=1; shift 2>/dev/null || true;;
esac

LOAD_MULTIPLIER="${CHUMP_DEADMAN_LOAD_MULTIPLIER:-3}"
MEM_THRESHOLD_PCT="${CHUMP_DEADMAN_MEM_THRESHOLD_PCT:-5}"
RISE_TIME_S="${CHUMP_DEADMAN_RISE_TIME_S:-600}"
SSH_TIMEOUT_S="${CHUMP_DEADMAN_SSH_TIMEOUT_S:-900}"

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
DEADMAN_STATE="$STATE_DIR/deadman-state"

# Emit an event to ambient.jsonl
emit_event() {
  local kind="$1"
  local detail="$2"
  mkdir -p "$STATE_DIR"
  local lockdir="${CHUMP_LOCKS_DIR:-.chump-locks}"
  mkdir -p "$lockdir"
  printf '{"ts":"%s","kind":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$detail" \
    >> "$lockdir/ambient.jsonl" 2>/dev/null || true
}

# Get current load and memory stats
get_load() {
  cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "0"
}

get_nproc() {
  nproc 2>/dev/null || echo "4"
}

get_mem_available_pct() {
  local avail memtotal
  avail=$(grep '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}')
  memtotal=$(grep '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
  if [ -z "$avail" ] || [ -z "$memtotal" ] || [ "$memtotal" -eq 0 ]; then
    echo "100"
    return
  fi
  awk "BEGIN { printf \"%.0f\", ($avail / $memtotal) * 100 }"
}

# Check if a condition has been true for RISE_TIME_S
check_sustained_condition() {
  local state_key="$1"
  local condition_true="$2"

  if [ "$condition_true" = "true" ]; then
    local now; now=$(date +%s)
    local start_time
    start_time=$(cat "$DEADMAN_STATE.$state_key" 2>/dev/null || echo "$now")
    echo "$now" > "$DEADMAN_STATE.$state_key"

    local duration=$((now - start_time))
    [ "$duration" -ge "$RISE_TIME_S" ] && return 0
    return 1
  else
    # Condition is false, clear the state
    rm -f "$DEADMAN_STATE.$state_key"
    return 1
  fi
}

# Kill the newest claude -p and cargo tree processes
kill_heaviest_processes() {
  local killed=0

  # Find and kill the newest `claude -p` process
  local claude_pid
  claude_pid=$(pgrep -f "claude -p" -o -t newest 2>/dev/null | head -1)
  if [ -n "$claude_pid" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "[DEADMAN-DRY-RUN] Would kill claude -p (PID $claude_pid)"
    else
      echo "[DEADMAN] Killing newest claude -p (PID $claude_pid)" >&2
      kill -9 "$claude_pid" 2>/dev/null || true
      killed=$((killed + 1))
    fi
  fi

  # Find and kill the newest `cargo tree` process
  local cargo_pid
  cargo_pid=$(pgrep -f "cargo tree" -o -t newest 2>/dev/null | head -1)
  if [ -n "$cargo_pid" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "[DEADMAN-DRY-RUN] Would kill cargo tree (PID $cargo_pid)"
    else
      echo "[DEADMAN] Killing newest cargo tree (PID $cargo_pid)" >&2
      kill -9 "$cargo_pid" 2>/dev/null || true
      killed=$((killed + 1))
    fi
  fi

  return $((killed > 0 ? 0 : 1))
}

# Trigger a hardware watchdog reboot
trigger_reboot() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[DEADMAN-DRY-RUN] Would trigger watchdog reboot"
    return
  fi

  echo "[DEADMAN] Triggering hardware watchdog reboot after ${SSH_TIMEOUT_S}s unresponsive sshd" >&2
  emit_event "deadman_reboot" "sshd unresponsive for ${SSH_TIMEOUT_S}s, triggering reboot"

  # Try systemd watchdog first
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reboot || true
  fi

  # Fallback: try kernel softdog or direct reboot
  /sbin/reboot -f || reboot -f || true
}

# Check SSH responsiveness
is_sshd_responsive() {
  timeout 5 bash -c "</dev/tcp/127.0.0.1/22" 2>/dev/null || return 1
}

# Main monitoring logic
if [ "$CHECK_ONLY" = "1" ]; then
  # Health report only
  local load_threshold
  load_threshold=$(awk "BEGIN { printf \"%.2f\", $(get_nproc) * $LOAD_MULTIPLIER }")
  local load; load=$(get_load)
  local mem_pct; mem_pct=$(get_mem_available_pct)

  echo "LOAD: $load (threshold: $load_threshold for >$(( RISE_TIME_S / 60 )) min)"
  echo "MEM:  ${mem_pct}% available (threshold: <${MEM_THRESHOLD_PCT}% for >$(( RISE_TIME_S / 60 )) min)"

  [ "$(echo "$load > $load_threshold" | bc 2>/dev/null || echo 0)" = "1" ] && echo "LOAD-ALARM: above threshold"
  [ "$mem_pct" -lt "$MEM_THRESHOLD_PCT" ] && echo "MEM-ALARM: below threshold"
  exit 0
fi

# Normal monitoring (one pass)
local load_threshold
load_threshold=$(awk "BEGIN { printf \"%.2f\", $(get_nproc) * $LOAD_MULTIPLIER }")
local load; load=$(get_load)
local mem_pct; mem_pct=$(get_mem_available_pct)

# Check load condition
local load_high="false"
[ "$(echo "$load > $load_threshold" | bc 2>/dev/null || echo 0)" = "1" ] && load_high="true"

# Check memory condition
local mem_low="false"
[ "$mem_pct" -lt "$MEM_THRESHOLD_PCT" ] && mem_low="true"

# Check if load has been high for RISE_TIME_S
if check_sustained_condition "load" "$load_high"; then
  echo "[DEADMAN] Load ${load} has been >${load_threshold} for ${RISE_TIME_S}s — killing processes" >&2
  kill_heaviest_processes
  emit_event "deadman_load_action" "load=${load} threshold=${load_threshold}"
fi

# Check if memory has been low for RISE_TIME_S
if check_sustained_condition "memory" "$mem_low"; then
  echo "[DEADMAN] MemAvailable ${mem_pct}% has been <${MEM_THRESHOLD_PCT}% for ${RISE_TIME_S}s — killing processes" >&2
  kill_heaviest_processes
  emit_event "deadman_memory_action" "mem_pct=${mem_pct} threshold=${MEM_THRESHOLD_PCT}"
fi

# Check SSH responsiveness for reboot decision
if ! is_sshd_responsive; then
  # sshd is unresponsive; check if it's been down long enough
  if check_sustained_condition "sshd" "true"; then
    trigger_reboot
  fi
else
  # sshd is responsive, clear the state
  rm -f "$DEADMAN_STATE.sshd"
fi

exit 0
