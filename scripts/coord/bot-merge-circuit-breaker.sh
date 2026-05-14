#!/usr/bin/env bash
# bot-merge-circuit-breaker.sh — INFRA-954
#
# Refuse to enter a wedge-prone bot-merge phase when that phase has timed
# out N times in the last window. Each bot_merge_hang event represents a
# paid-for `claude -p` invocation that produced no output before timeout
# (~15k tokens per hit, per the META-055 audit). After three in an hour
# the underlying cause is almost never transient — it's typically a hung
# child process, a corrupted target/, or a network partition. Re-running
# burns more tokens without changing the outcome.
#
# The breaker is derived from ambient.jsonl (no separate state file), so
# clearing it requires the underlying problem to actually subside (events
# age out of the window) OR an explicit operator override.
#
# Usage:
#   source scripts/coord/bot-merge-circuit-breaker.sh
#   if ! circuit_breaker_check <phase>; then
#       # phase has tripped — fail closed
#       exit 124
#   fi
#
#   scripts/coord/bot-merge-circuit-breaker.sh check <phase>
#       Exits 0 if the phase is safe to run, 124 if tripped (matching
#       the timeout exit code convention).
#
#   scripts/coord/bot-merge-circuit-breaker.sh status
#       Prints a table of (phase, hang_count_last_1h, status) lines.
#
#   scripts/coord/bot-merge-circuit-breaker.sh clear
#       Drops a CHUMP_CIRCUIT_BREAKER_OVERRIDE marker so the next check
#       passes regardless of history. Marker is single-use; auto-deleted
#       on first successful check.
#
# Env:
#   CHUMP_CIRCUIT_BREAKER_DISABLE=1  bypass entirely (escape hatch)
#   CHUMP_CIRCUIT_BREAKER_THRESHOLD  hangs in window before trip (default 3)
#   CHUMP_CIRCUIT_BREAKER_WINDOW_S   window in seconds (default 3600 = 1h)
#   CHUMP_CIRCUIT_BREAKER_OVERRIDE   set to skip THIS check only (auto-clears)

set -uo pipefail

_CB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB_REPO_ROOT="${REPO_ROOT:-$(cd "$_CB_SCRIPT_DIR/../.." && pwd)}"
CB_AMBIENT="${CHUMP_AMBIENT_LOG:-$CB_REPO_ROOT/.chump-locks/ambient.jsonl}"
CB_MARKER_DIR="${CHUMP_CIRCUIT_BREAKER_DIR:-$CB_REPO_ROOT/.chump-locks}"
CB_OVERRIDE_FILE="$CB_MARKER_DIR/.circuit-breaker-override"
CB_THRESHOLD="${CHUMP_CIRCUIT_BREAKER_THRESHOLD:-3}"
CB_WINDOW_S="${CHUMP_CIRCUIT_BREAKER_WINDOW_S:-3600}"
CB_DISABLED="${CHUMP_CIRCUIT_BREAKER_DISABLE:-0}"

_cb_log() { printf '[circuit-breaker] %s\n' "$*" >&2; }

# Count bot_merge_hang events for `phase` in the last CB_WINDOW_S seconds.
_cb_count_recent_hangs() {
  local phase="$1"
  [[ -f "$CB_AMBIENT" ]] || { echo 0; return; }
  local cutoff
  cutoff="$(python3 -c "
import datetime
print((datetime.datetime.utcnow() - datetime.timedelta(seconds=$CB_WINDOW_S)).strftime('%Y-%m-%dT%H:%M:%SZ')
)" 2>/dev/null || echo "0000-00-00T00:00:00Z")"
  awk -v c="$cutoff" -v p="\"phase\":\"$phase\"" '
    /"kind":"bot_merge_hang"/ && index($0, p) {
      if (match($0, /"ts":"[^"]+"/)) {
        ts = substr($0, RSTART+6, RLENGTH-7)
        if (ts > c) count++
      }
    }
    END { print count+0 }
  ' "$CB_AMBIENT"
}

# circuit_breaker_check <phase>
# Returns 0 if safe to run, non-zero (124) if the breaker is tripped.
circuit_breaker_check() {
  if [[ "$CB_DISABLED" == "1" ]]; then
    return 0
  fi
  local phase="${1:?circuit_breaker_check requires a phase name}"

  # One-shot override: consume the marker and pass.
  if [[ -f "$CB_OVERRIDE_FILE" ]]; then
    _cb_log "override marker found at $CB_OVERRIDE_FILE — consuming (one-shot)"
    rm -f "$CB_OVERRIDE_FILE"
    return 0
  fi

  local count; count=$(_cb_count_recent_hangs "$phase")
  if [[ "$count" -ge "$CB_THRESHOLD" ]]; then
    _cb_log "TRIPPED: phase '$phase' has $count bot_merge_hang events in last $((CB_WINDOW_S / 60))m (threshold $CB_THRESHOLD)"
    _cb_log "Run \`scripts/coord/bot-merge-circuit-breaker.sh clear\` after fixing the root cause"
    _cb_log "or set CHUMP_CIRCUIT_BREAKER_DISABLE=1 once you understand why this phase is wedging."
    return 124
  fi
  return 0
}

# Drop a single-use override marker.
circuit_breaker_clear() {
  mkdir -p "$CB_MARKER_DIR"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$CB_OVERRIDE_FILE"
  _cb_log "override marker written; next check will pass (then auto-clear)"
}

# Print one line per known wedge-prone phase with current count + status.
circuit_breaker_status() {
  # The phase names in run_timed_hb labels collapse multi-word into single
  # tokens via the "label" string; just iterate the distinct prefixes here.
  local distinct=("cargo clippy --workspace --all-targets" "cargo test" "cargo fmt" "git push" "git fetch" "gh pr create")
  echo "phase                                         | hangs(${CB_WINDOW_S}s) | status"
  echo "----------------------------------------------|---------:|--------"
  local p count status
  for p in "${distinct[@]}"; do
    count=$(_cb_count_recent_hangs "$p")
    if [[ "$count" -ge "$CB_THRESHOLD" ]]; then
      status="TRIPPED"
    else
      status="ok"
    fi
    printf '%-46s| %8d | %s\n' "$p" "$count" "$status"
  done
}

# Direct CLI invocation.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  case "${1:-}" in
    check)   circuit_breaker_check "${2:?phase name required}"; exit $? ;;
    clear)   circuit_breaker_clear ;;
    status)  circuit_breaker_status ;;
    *)
      echo "Usage: $0 {check <phase>|clear|status}" >&2
      exit 1
      ;;
  esac
fi
