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
  if (( post_pct < PAGE_THRESHOLD )); then
    if [[ -x "$RECALL" ]]; then
      "$RECALL" --condition DISK_CRITICAL \
        --reason "post-reactor disk still ${post_pct}% free (<${PAGE_THRESHOLD}%); tier-${esc_tier} reap did not recover sufficient headroom" \
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
