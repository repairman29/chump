#!/usr/bin/env bash
# cloud-shift-doorbell.sh — INFRA-8070: fire the Chump-Cloud-Agent routine when
# there is eligible dispatch work or a queued cloud-default reply.
#
#   cloud-shift-doorbell.sh tick                 # one waker cycle (run from a timer)
#   cloud-shift-doorbell.sh record ok|junk|fail  # shift reports its outcome
#   cloud-shift-doorbell.sh status
#
# Guards (trigger-side): FLEET_DISPATCH_PAUSED kill switch, min gap between
# fires (default 900s), stop after 3 consecutive junk/fail until `reset`.
# Config env: CHUMP_DOORBELL_STATE_DIR, CHUMP_DOORBELL_MIN_GAP_S,
# CHUMP_DOORBELL_MAX_FAILS, CHUMP_DOORBELL_WORK_CMD / _REPLY_CMD (print a count),
# CHUMP_DOORBELL_FIRE_CMD (default: POST to $CHUMP_ROUTINE_RUN_URL with the OAuth token).
set -u

STATE_DIR=${CHUMP_DOORBELL_STATE_DIR:-$HOME/.chump/doorbell}
MIN_GAP=${CHUMP_DOORBELL_MIN_GAP_S:-900}
MAX_FAILS=${CHUMP_DOORBELL_MAX_FAILS:-3}
NOW=${CHUMP_DOORBELL_NOW:-$(date +%s)}
AMBIENT=${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}
mkdir -p "$STATE_DIR"

emit() { # kind reason
  printf '{"ts":"%s","kind":"%s","reason":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >>"$AMBIENT" 2>/dev/null || true
}
read_int() { local v; v=$(cat "$1" 2>/dev/null); [[ $v =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }

default_work() { chump gap list --status open 2>/dev/null | grep -c . ; }
default_reply() {
  nats consumer info "${CHUMP_DOORBELL_STREAM:-CHUMP}" cloud-default --json 2>/dev/null \
    | sed -n 's/.*"num_pending": *\([0-9]*\).*/\1/p' | head -1
}
default_fire() {
  local tok=${CLAUDE_CODE_OAUTH_TOKEN:-$(sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p' "$HOME/.chump/oauth-token.json" 2>/dev/null)}
  [ -n "${CHUMP_ROUTINE_RUN_URL:-}" ] && [ -n "$tok" ] || return 1
  curl -fsS -X POST -H "Authorization: Bearer $tok" "$CHUMP_ROUTINE_RUN_URL" >/dev/null
}

cmd_tick() {
  if [ -n "${FLEET_DISPATCH_PAUSED:-}" ] || [ -e "$STATE_DIR/FLEET_DISPATCH_PAUSED" ]; then
    emit cloud_doorbell_skipped paused; echo "skip: paused"; return 0
  fi
  if [ "$(read_int "$STATE_DIR/consec_fail")" -ge "$MAX_FAILS" ]; then
    emit cloud_doorbell_skipped circuit_open; echo "skip: $MAX_FAILS consecutive junk/fail (run reset)"; return 0
  fi
  local last; last=$(read_int "$STATE_DIR/last_fire")
  if [ $((NOW - last)) -lt "$MIN_GAP" ]; then
    echo "skip: min gap ($((NOW - last))s < ${MIN_GAP}s)"; return 0
  fi
  local work reply
  work=$(${CHUMP_DOORBELL_WORK_CMD:-default_work} 2>/dev/null); work=${work:-0}
  reply=$(${CHUMP_DOORBELL_REPLY_CMD:-default_reply} 2>/dev/null); reply=${reply:-0}
  if [ "${work:-0}" -le 0 ] && [ "${reply:-0}" -le 0 ]; then
    echo "skip: nothing eligible"; return 0
  fi
  if ${CHUMP_DOORBELL_FIRE_CMD:-default_fire}; then
    echo "$NOW" >"$STATE_DIR/last_fire"
    emit cloud_doorbell_fired "work=$work reply=$reply"; echo "fired (work=$work reply=$reply)"
  else
    echo "$NOW" >"$STATE_DIR/last_fire"   # failed fires still respect the min gap
    echo $(( $(read_int "$STATE_DIR/consec_fail") + 1 )) >"$STATE_DIR/consec_fail"
    emit cloud_doorbell_fire_failed "work=$work reply=$reply"; echo "fire failed"; return 1
  fi
}

cmd_record() {
  case "${1:-}" in
    ok) echo 0 >"$STATE_DIR/consec_fail" ;;
    junk|fail) echo $(( $(read_int "$STATE_DIR/consec_fail") + 1 )) >"$STATE_DIR/consec_fail" ;;
    *) echo "usage: record ok|junk|fail" >&2; return 2 ;;
  esac
}

case "${1:-}" in
  tick) cmd_tick ;;
  record) shift; cmd_record "$@" ;;
  reset) echo 0 >"$STATE_DIR/consec_fail" ;;
  status) echo "last_fire=$(read_int "$STATE_DIR/last_fire") consec_fail=$(read_int "$STATE_DIR/consec_fail")" ;;
  *) echo "usage: $0 tick|record <ok|junk|fail>|reset|status" >&2; exit 2 ;;
esac
