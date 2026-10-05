#!/usr/bin/env bash
# scripts/coord/cost-cap-watch.sh — RESILIENT-415
#
# INCIDENT: the weekly Claude subscription cap exhausted with no live
# free-tier floor to fall back onto (the RESILIENT-676/1086
# fleet_backend_no_live_floor path in scripts/dispatch/worker.sh) and the
# fleet just... sat there. Nothing watched for the cap resetting, so the
# halt lasted ~2 days until Jeff noticed and restarted the fleet by hand
# over Swift. A cap exhaustion is a KNOWN-TRANSIENT condition (the cap
# resets on a schedule) — the fleet should park itself loudly, then poll
# for the reset and resume on its own, the same governance pattern
# disk-critical-reactor.sh established for disk-critical halts (RESILIENT-326:
# no organ may halt the fleet without a tested auto-recovery path + a page).
#
# Behavior:
#   1. Watch ambient.jsonl for a cap-exhaustion signal:
#        - kind=fleet_backend_no_live_floor (sub failing AND no live
#          free-tier floor — RESILIENT-676/1086), or
#        - kind=cost_cap_exceeded
#   2. On first sighting (debounced), PARK the fleet: save the current
#      AUTONOMY_LEVEL, set it to 0, emit kind=cost_cap_watch_parked, and
#      page the operator via operator-recall.sh --condition COST_CAP.
#   3. While parked, periodically PROBE whether the cap has reset (default:
#      invoke `claude -p` with a trivial prompt; test seam:
#      CHUMP_FAKE_COST_CAP_PROBE=live|dead skips the real call).
#   4. On a successful probe, RESUME: restore AUTONOMY_LEVEL to its
#      pre-halt value, emit kind=cost_cap_watch_resumed, and clear the
#      park-state file. Never leaves the fleet halted forever — the abort
#      path (probe keeps failing) just keeps polling, it does not give up.
#
# CLI (test + ops seams):
#   --park-check    one-shot: scan ambient for exhaustion, park if found and
#                   not already parked. Exit 0 if parked (or already
#                   parked), 1 if nothing to do.
#   --resume-check  one-shot: if parked, probe; resume on success. Exit 0 if
#                   resumed, 1 if still parked or not parked at all.
#   (no args)       long-lived loop: tails ambient for the exhaustion
#                   signal, polls --resume-check every CHUMP_COST_CAP_WATCH_POLL_S
#                   while parked.
#
# Env:
#   CHUMP_REPO                         repo root
#   CHUMP_AMBIENT_LOG                  ambient.jsonl path
#   CHUMP_AUTON_FILE                   AUTONOMY_LEVEL file (mirrors disk-critical-reactor.sh)
#   CHUMP_COST_CAP_PARK_FILE           park-state file (prior level + reason)
#   CHUMP_COST_CAP_WATCH_POLL_S        probe interval while parked (default 300)
#   CHUMP_COST_CAP_PROBE_CMD           override probe command (default: `claude -p ping --max-turns 1`)
#   CHUMP_FAKE_COST_CAP_PROBE          live|dead — hermetic test seam, skips the real probe

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-${CHUMP_HOME:-/Users/jeffadkins/Projects/Chump}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
RECALL="$REPO_ROOT/scripts/dispatch/operator-recall.sh"
AUTON_FILE="${CHUMP_AUTON_FILE:-$HOME/.chump/AUTONOMY_LEVEL}"
STATE_DIR="$REPO_ROOT/.chump-locks"
PARK_FILE="${CHUMP_COST_CAP_PARK_FILE:-$STATE_DIR/cost-cap-watch.parked.json}"
LAST_PARK_FILE="$STATE_DIR/cost-cap-watch.last-park"
POLL_S="${CHUMP_COST_CAP_WATCH_POLL_S:-300}"
DEBOUNCE="${CHUMP_COST_CAP_WATCH_DEBOUNCE_SECS:-60}"
PROBE_CMD="${CHUMP_COST_CAP_PROBE_CMD:-claude -p ping --max-turns 1}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

emit() {
  local payload="$1"
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s",%s}\n' "$(ts)" "$payload" >> "$AMBIENT" 2>/dev/null || true
}

is_parked() { [[ -f "$PARK_FILE" ]]; }

# Scan the last CHUMP_COST_CAP_WATCH_LOOKBACK lines of ambient for an
# unresolved cap-exhaustion signal. We don't time-window this (unlike
# operator-recall's hour-scoped scans) because once parked we want to stay
# parked until an explicit resume, regardless of how old the triggering
# line is.
cap_exhausted_signal() {
  [[ -f "$AMBIENT" ]] || return 1
  grep -qE '"kind":"(fleet_backend_no_live_floor|cost_cap_exceeded)"' "$AMBIENT" 2>/dev/null
}

# Scanner anchors for the event-registry verify rule:
#   "kind":"cost_cap_watch_parked"
#   "kind":"cost_cap_watch_resumed"
park() {
  if is_parked; then
    return 0
  fi
  local now last
  now=$(date +%s)
  last=$(cat "$LAST_PARK_FILE" 2>/dev/null || echo 0)
  if (( now - last < DEBOUNCE )); then
    return 1
  fi
  echo "$now" > "$LAST_PARK_FILE" 2>/dev/null || true

  local prior_level; prior_level="$(cat "$AUTON_FILE" 2>/dev/null || echo 5)"
  [[ "$prior_level" =~ ^[0-9]+$ ]] || prior_level=5

  mkdir -p "$(dirname "$AUTON_FILE")" "$(dirname "$PARK_FILE")" 2>/dev/null || true
  echo 0 > "$AUTON_FILE" 2>/dev/null || true
  printf '{"prior_level":%d,"parked_at":"%s"}\n' "$prior_level" "$(ts)" > "$PARK_FILE" 2>/dev/null || true

  emit "\"kind\":\"cost_cap_watch_parked\",\"prior_level\":$prior_level,\"reason\":\"cap exhaustion signal (fleet_backend_no_live_floor / cost_cap_exceeded) with no live free-tier floor\""
  echo "[cost-cap-watch] PARKED fleet (AUTONOMY_LEVEL 0, was $prior_level) — cap exhaustion detected" >&2

  if [[ -x "$RECALL" ]]; then
    "$RECALL" --condition COST_CAP \
      --reason "cost-cap-watch parked the fleet (AUTONOMY_LEVEL 0, was $prior_level) on cap exhaustion with no live free-tier floor; auto-resumes when the sub cap resets" \
      >/dev/null 2>&1 || true
  fi
  return 0
}

# Returns 0 if the cap has reset (sub usable again), 1 otherwise.
probe_cap_reset() {
  if [[ -n "${CHUMP_FAKE_COST_CAP_PROBE:-}" ]]; then
    case "$CHUMP_FAKE_COST_CAP_PROBE" in
      live) return 0 ;;
      *) return 1 ;;
    esac
  fi
  # shellcheck disable=SC2086
  timeout 60 $PROBE_CMD >/dev/null 2>&1
}

resume() {
  is_parked || return 1

  local prior_level
  prior_level="$(grep -oE '"prior_level":[0-9]+' "$PARK_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+')"
  [[ "$prior_level" =~ ^[0-9]+$ ]] || prior_level=5

  echo "$prior_level" > "$AUTON_FILE" 2>/dev/null || true
  rm -f "$PARK_FILE" "$LAST_PARK_FILE" 2>/dev/null || true

  emit "\"kind\":\"cost_cap_watch_resumed\",\"restored_level\":$prior_level,\"reason\":\"cap reset probe succeeded\""
  echo "[cost-cap-watch] RESUMED fleet (AUTONOMY_LEVEL restored to $prior_level) — cap reset detected" >&2
  return 0
}

park_check() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  if is_parked; then
    return 0
  fi
  if cap_exhausted_signal; then
    park
    return $?
  fi
  return 1
}

resume_check() {
  is_parked || return 1
  if probe_cap_reset; then
    resume
    return $?
  fi
  echo "[cost-cap-watch] still parked — cap reset probe failed, will retry in ${POLL_S}s" >&2
  return 1
}

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  touch "$AMBIENT" 2>/dev/null || true
  echo "[cost-cap-watch] starting; tailing $AMBIENT (poll=${POLL_S}s while parked)" >&2

  tail -n 0 -F "$AMBIENT" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *'"kind":"fleet_backend_no_live_floor"'*|*'"kind":"cost_cap_exceeded"'*)
        park || true
        ;;
    esac
    if is_parked; then
      resume_check || true
    fi
  done &
  local tail_pid=$!

  while true; do
    sleep "$POLL_S"
    if is_parked; then
      resume_check || true
    fi
  done
  wait "$tail_pid" 2>/dev/null || true
}

case "${1:-}" in
  --park-check) park_check; exit $? ;;
  --resume-check) resume_check; exit $? ;;
  --once)
    park_check || true
    is_parked && resume_check
    exit 0
    ;;
  "") main ;;
  *) echo "usage: $0 [--park-check|--resume-check|--once]" >&2; exit 2 ;;
esac
