# Optional lock so only one heartbeat/self-improve round runs at a time (reduces load on 8000).
# Source this from heartbeat scripts. Use HEARTBEAT_LOCK=1 to enable.
#
# acquire_heartbeat_lock [timeout_sec]  — returns 0 if acquired, 1 if timeout. Lock stale after 15 min.
# release_heartbeat_lock                — releases lock if current PID owns it.

HEARTBEAT_LOCK_FILE="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}/logs/heartbeat.lock"
HEARTBEAT_LOCK_STALE_SEC=900

acquire_heartbeat_lock() {
  local timeout="${1:-120}"
  local start=$(date +%s)
  local now dir
  dir="$(dirname "$HEARTBEAT_LOCK_FILE")"
  mkdir -p "$dir"
  while true; do
    now=$(date +%s)
    if [[ -f "$HEARTBEAT_LOCK_FILE" ]]; then
      local content
      content=$(cat "$HEARTBEAT_LOCK_FILE" 2>/dev/null) || true
      local lock_pid lock_ts
      lock_pid="${content%% *}"
      lock_ts="${content#* }"
      if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        if [[ $((now - lock_ts)) -gt $HEARTBEAT_LOCK_STALE_SEC ]]; then
          rm -f "$HEARTBEAT_LOCK_FILE"
        elif [[ $((now - start)) -ge "$timeout" ]]; then
          return 1
        else
          sleep 15
          continue
        fi
      else
        rm -f "$HEARTBEAT_LOCK_FILE"
      fi
    fi
    echo "$$ $now" > "$HEARTBEAT_LOCK_FILE"
    return 0
  done
}

release_heartbeat_lock() {
  if [[ -f "$HEARTBEAT_LOCK_FILE" ]]; then
    local content
    content=$(cat "$HEARTBEAT_LOCK_FILE" 2>/dev/null) || true
    [[ "${content%% *}" == "$$" ]] && rm -f "$HEARTBEAT_LOCK_FILE"
  fi
}
