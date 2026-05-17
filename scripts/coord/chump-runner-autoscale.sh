#!/usr/bin/env bash
# chump-runner-autoscale.sh — INFRA-1535 (slice 1)
#
# Polls GitHub Actions queue depth + online self-hosted runner count and
# scales the runner pool on the M4 between [min, max]. Reaps idle runners
# and spawns new ones when the queue saturates.
#
# Scale-up:   queue_depth > online * 2 sustained 2 min AND online < max
# Scale-down: runner idle > 10 min AND online > min
#
# Slice 1 scope: M4 only (single machine, max 2 runners). Pi mesh follow-up.
#
# Usage:
#   scripts/coord/chump-runner-autoscale.sh                # foreground loop
#   scripts/coord/chump-runner-autoscale.sh --once         # one decision cycle
#   scripts/coord/chump-runner-autoscale.sh --status       # print current state
#   scripts/coord/chump-runner-autoscale.sh --uninstall    # remove launchd plist
#
# Architecture: docs/process/SELF_HOSTED_RUNNERS.md (INFRA-1534)
#
# Rust-First-Bypass: shell glue around gh api + launchctl; per-cycle decisions
# write only to ambient.jsonl (kind=runner_scaled emit, READ-mostly otherwise).
# Per META-064 shell-OK criteria: glue between existing CLI tools, single
# host scope, <200 LOC. The structural decision logic moves to Rust when
# the per-machine ceiling is broken (Pi mesh ≥ 3 nodes).

set -euo pipefail

# shellcheck source=lib/github_cache.sh
source "$(dirname "$0")/lib/github_cache.sh"

REPO_OWNER="${CHUMP_REPO_OWNER:-repairman29}"
REPO_NAME="${CHUMP_REPO_NAME:-chump}"
MIN_RUNNERS="${CHUMP_RUNNER_MIN:-1}"
MAX_RUNNERS="${CHUMP_RUNNER_M4_MAX:-2}"
POLL_INTERVAL_SECS="${CHUMP_RUNNER_POLL_SECS:-60}"
SUSTAIN_SECS="${CHUMP_RUNNER_SUSTAIN_SECS:-120}"
IDLE_REAP_SECS="${CHUMP_RUNNER_IDLE_REAP_SECS:-600}"
INSTALL_SCRIPT="${CHUMP_INSTALL_SCRIPT:-$(dirname "$0")/../setup/install-self-hosted-runner.sh}"
AMBIENT="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-$(pwd)}/.chump-locks/ambient.jsonl}"
STATE_FILE="${CHUMP_AUTOSCALE_STATE:-/tmp/chump-runner-autoscale.state}"

emit_kind() {
  local kind="$1" payload="$2"
  printf '{"ts":"%s","kind":"%s",%s}\n' \
    "$(date -u +%FT%TZ)" "$kind" "$payload" \
    >> "$AMBIENT" 2>/dev/null || true
}

log() { echo "[$(date -u +%FT%TZ)] $*"; }

count_online() {
  chump_gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq '[.runners[] | select(.status=="online" and (.labels[].name | contains("chump-fleet")))] | length' 2>/dev/null || echo 0
}

count_queued() {
  gh run list -R "$REPO_OWNER/$REPO_NAME" --limit 50 --json status \
    --jq '[.[] | select(.status=="queued")] | length' 2>/dev/null || echo 0
}

list_idle_runners() {
  # Idle = online AND busy=false. Returns "id name" tab-separated.
  chump_gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq '.runners[] | select(.status=="online" and .busy==false and (.labels[].name | contains("chump-fleet"))) | "\(.id)\t\(.name)"' 2>/dev/null
}

list_busy_runners() {
  chump_gh api "/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
    --jq '.runners[] | select(.status=="online" and .busy==true and (.labels[].name | contains("chump-fleet"))) | "\(.id)\t\(.name)"' 2>/dev/null
}

cmd_status() {
  local online queued idle busy
  online=$(count_online)
  queued=$(count_queued)
  idle=$(list_idle_runners | wc -l | tr -d ' ')
  busy=$(list_busy_runners | wc -l | tr -d ' ')
  echo "online=$online (idle=$idle busy=$busy)  queued_workflows=$queued  min=$MIN_RUNNERS  max=$MAX_RUNNERS"
  list_idle_runners | sed 's/^/  idle: /'
  list_busy_runners | sed 's/^/  busy: /'
}

# Read sustained-state from STATE_FILE.
# Format: <last_decision_ts>\t<consecutive_scale_up_polls>\t<idle_first_seen_runner_id>:<idle_first_seen_ts>
read_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo -e "0\t0\t"
  fi
}
write_state() {
  echo -e "$1\t$2\t$3" > "$STATE_FILE"
}

decide_and_act() {
  local online queued idle_first_seen idle_runner_id
  online=$(count_online)
  queued=$(count_queued)

  IFS=$'\t' read -r _last_ts scale_up_polls idle_track < <(read_state)
  : "${scale_up_polls:=0}"
  : "${idle_track:=}"

  log "decide: online=$online queued=$queued scale_up_polls=$scale_up_polls"

  # === Scale-up branch ===
  if [ "$queued" -gt $((online * 2)) ] && [ "$online" -lt "$MAX_RUNNERS" ]; then
    scale_up_polls=$((scale_up_polls + 1))
    if [ "$((scale_up_polls * POLL_INTERVAL_SECS))" -ge "$SUSTAIN_SECS" ]; then
      local next_slot=$((online + 1))
      log "SCALE-UP: queue=$queued > 2*online=$online, spawning slot $next_slot"
      emit_kind "runner_scaled" "\"action\":\"spawn\",\"reason\":\"queue_depth_sustained\",\"queued\":$queued,\"online_before\":$online,\"slot\":$next_slot"
      if [ -x "$INSTALL_SCRIPT" ]; then
        CHUMP_RUNNER_SLOT="$next_slot" \
          RUNNER_NAME="$(hostname -s | tr '[:upper:]' '[:lower:]')-$next_slot" \
          RUNNER_DIR="$HOME/actions-runner-chump-$next_slot" \
          "$INSTALL_SCRIPT" 2>&1 | tail -3 | sed 's/^/  spawn> /'
      else
        log "  WARN: install script not executable: $INSTALL_SCRIPT"
      fi
      scale_up_polls=0
    fi
  else
    scale_up_polls=0
  fi

  # === Scale-down branch ===
  if [ "$online" -gt "$MIN_RUNNERS" ] && [ "$queued" -lt "$online" ]; then
    while IFS=$'\t' read -r rid rname; do
      [ -z "$rid" ] && continue
      now=$(date +%s)
      if [[ "$idle_track" == "$rid:"* ]]; then
        seen_at="${idle_track#$rid:}"
        if [ "$((now - seen_at))" -ge "$IDLE_REAP_SECS" ]; then
          log "SCALE-DOWN: runner $rid ($rname) idle for $((now - seen_at))s, reaping"
          emit_kind "runner_scaled" "\"action\":\"reap\",\"reason\":\"idle\",\"online_before\":$online,\"runner_id\":$rid,\"runner_name\":\"$rname\""
          # Deregister from GitHub
          chump_gh api -X DELETE "/repos/$REPO_OWNER/$REPO_NAME/actions/runners/$rid" 2>&1 | head -1 | sed 's/^/  reap> /'
          # Stop launchd service (if naming matches our convention)
          local plist="$HOME/Library/LaunchAgents/com.chump.actions-runner-$(echo "$rname" | grep -oE '[0-9]+$').plist"
          [ -f "$plist" ] && launchctl bootout "gui/$UID" "$plist" 2>/dev/null || true
          idle_track=""
          break  # one reap per cycle
        fi
      else
        idle_track="$rid:$now"
        log "  noting idle: $rname (id=$rid) at $now"
      fi
    done < <(list_idle_runners)
  else
    idle_track=""
  fi

  write_state "$(date +%s)" "$scale_up_polls" "$idle_track"
}

cmd_loop() {
  log "autoscale loop starting: min=$MIN_RUNNERS max=$MAX_RUNNERS poll=${POLL_INTERVAL_SECS}s sustain=${SUSTAIN_SECS}s reap=${IDLE_REAP_SECS}s"
  while true; do
    decide_and_act || log "  decide_and_act failed (non-fatal); continuing"
    sleep "$POLL_INTERVAL_SECS"
  done
}

cmd_once() {
  decide_and_act
}

cmd_uninstall() {
  local plist="$HOME/Library/LaunchAgents/com.chump.runner-autoscale.plist"
  if [ -f "$plist" ]; then
    launchctl bootout "gui/$UID" "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "Removed autoscale plist."
  fi
  rm -f "$STATE_FILE"
}

case "${1:-}" in
  --status)    cmd_status ;;
  --once)      cmd_once ;;
  --uninstall) cmd_uninstall ;;
  -h|--help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    exit 0 ;;
  "")          cmd_loop ;;
  *)           echo "Unknown arg: $1"; exit 1 ;;
esac
