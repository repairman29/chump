#!/usr/bin/env bash
# Parse Chump timing lines from companion.log (CHUMP_LOG_TIMING=1).
# Groups api_request_ms by turn and prints per-turn: request_id, turn_ms, agent_run_ms, api_sum_ms, overhead_ms.
# Usage: ./parse-timing-log.sh [--summary] [companion.log]
#   With no file: reads stdin (e.g. cat ~/chump/logs/companion.log | ./parse-timing-log.sh).
#   --summary: append min/max/avg turn_ms and agent_run_ms over the parsed segment.
set -euo pipefail

SUMMARY=0
FILE=""
for arg in "$@"; do
  if [[ "$arg" == "--summary" ]]; then
    SUMMARY=1
  else
    FILE="$arg"
  fi
done

awk -v summary="$SUMMARY" '
function get_val(line, key) {
  if (match(line, key "=[0-9]+")) {
    return substr(line, RSTART + length(key) + 1, RLENGTH - length(key) - 1) + 0
  }
  return ""
}
function get_request_id(line) {
  if (match(line, /request_id=[^ ]+/)) {
    return substr(line, RSTART + 11, RLENGTH - 11)
  }
  return ""
}
/\[timing\] request_id=/ && /turn_ms=/ && /agent_run_ms=/ {
  if (req_id != "") {
    overhead = (agent_run_ms == "" ? 0 : agent_run_ms) - api_sum
    if (overhead < 0) overhead = 0
    printf "request_id=%s turn_ms=%s agent_run_ms=%s api_sum_ms=%s overhead_ms=%s\n", req_id, turn_ms, agent_run_ms, api_sum, overhead
    if (summary) {
      t = turn_ms + 0; a = agent_run_ms + 0
      if (nr == 0 || t < min_t) min_t = t; if (nr == 0 || t > max_t) max_t = t; sum_t += t
      if (nr == 0 || a < min_a) min_a = a; if (nr == 0 || a > max_a) max_a = a; sum_a += a
      nr++
    }
  }
  req_id = get_request_id($0); turn_ms = get_val($0, "turn_ms"); agent_run_ms = get_val($0, "agent_run_ms"); api_sum = 0
  next
}
/\[timing\] api_request_ms=/ { ms = get_val($0, "api_request_ms"); if (ms != "") api_sum += ms; next }
END {
  if (req_id != "") {
    overhead = (agent_run_ms == "" ? 0 : agent_run_ms) - api_sum
    if (overhead < 0) overhead = 0
    printf "request_id=%s turn_ms=%s agent_run_ms=%s api_sum_ms=%s overhead_ms=%s\n", req_id, turn_ms, agent_run_ms, api_sum, overhead
    if (summary) { t = turn_ms + 0; a = agent_run_ms + 0; if (nr == 0 || t < min_t) min_t = t; if (nr == 0 || t > max_t) max_t = t; sum_t += t; if (nr == 0 || a < min_a) min_a = a; if (nr == 0 || a > max_a) max_a = a; sum_a += a; nr++ }
  }
  if (summary && nr > 0) printf "\n# summary: turns=%d turn_ms min=%d max=%d avg=%d  agent_run_ms min=%d max=%d avg=%d\n", nr, min_t, max_t, int(sum_t/nr), min_a, max_a, int(sum_a/nr)
}
' ${FILE:+"$FILE"}