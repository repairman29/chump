#!/usr/bin/env bash
# INFRA-2352 (META-269 sub-3): daemon-silent meta-monitor.
#
# Reads scripts/coord/daemon-expectations.yaml, counts each daemon's
# expected ambient event-kinds in the last hour, and emits
# kind=daemon_silent when a daemon is LOADED but emitting nothing.
#
# Designed to be invoked on a 5-min launchd interval (sub-hourly cadence
# fine because we look at a rolling 60-min window — silence is durable).
#
# Today's session (META-269) demonstrated the gap: fix-trunk-dispatcher
# sat silent for 24h without anyone noticing. This monitor closes that.
#
# Exit codes:
#   0 — monitor ran cleanly (silent daemons emit ambient events)
#   1 — internal error (yaml unreadable, ambient missing, etc.)
#
# Bypass: CHUMP_DAEMON_SILENCE_DISABLE=1 short-circuits.
# Window override: CHUMP_DAEMON_SILENCE_WINDOW_SECS (default 3600).
#
# Emitted ambient kinds (registered for event-registry parity):
#   scanner-anchor: "kind":"daemon_silent"
#   scanner-anchor: "kind":"daemon_silence_monitor_tick"
# Mock paths for testing:
#   CHUMP_DAEMON_SILENCE_AMBIENT_PATH (default .chump-locks/ambient.jsonl)
#   CHUMP_DAEMON_SILENCE_EXPECTATIONS (default scripts/coord/daemon-expectations.yaml)
#   CHUMP_DAEMON_SILENCE_LAUNCHCTL_LIST (default $(launchctl list))
set -euo pipefail

if [ "${CHUMP_DAEMON_SILENCE_DISABLE:-0}" = "1" ]; then
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

AMBIENT_PATH="${CHUMP_DAEMON_SILENCE_AMBIENT_PATH:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
EXPECTATIONS="${CHUMP_DAEMON_SILENCE_EXPECTATIONS:-$REPO_ROOT/scripts/coord/daemon-expectations.yaml}"
WINDOW_SECS="${CHUMP_DAEMON_SILENCE_WINDOW_SECS:-3600}"

if [ ! -f "$EXPECTATIONS" ]; then
  echo "[daemon-silence-monitor] ERROR: expectations file missing: $EXPECTATIONS" >&2
  exit 1
fi

# Get LOADED daemon labels. Allow override for testing.
LAUNCHCTL_OUT="${CHUMP_DAEMON_SILENCE_LAUNCHCTL_LIST:-}"
if [ -z "$LAUNCHCTL_OUT" ]; then
  if command -v launchctl >/dev/null 2>&1; then
    LAUNCHCTL_OUT="$(launchctl list 2>/dev/null || echo "")"
  else
    LAUNCHCTL_OUT=""
  fi
fi

# Cutoff timestamp: now - WINDOW_SECS in ISO-8601 UTC.
NOW_EPOCH="$(date -u +%s)"
CUTOFF_EPOCH=$((NOW_EPOCH - WINDOW_SECS))

# Helper: emit ambient event.
emit_ambient() {
  local kind="$1"
  local daemon="$2"
  local expected_kinds="$3"
  local actual_count="$4"
  local diagnosis="$5"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  line=$(printf '{"ts":"%s","kind":"%s","source":"daemon-silence-monitor","daemon":"%s","expected_kinds":"%s","actual_count":%s,"window_secs":%s,"diagnosis":"%s"}' \
    "$ts" "$kind" "$daemon" "$expected_kinds" "$actual_count" "$WINDOW_SECS" "$diagnosis")
  echo "$line" >> "$AMBIENT_PATH"
  echo "[daemon-silence-monitor] EMIT: $line" >&2
}

# Helper: count occurrences in ambient.jsonl since cutoff.
# Args: list of kinds (space-separated string)
count_recent_kinds() {
  local kinds_csv="$1"
  if [ ! -f "$AMBIENT_PATH" ]; then
    echo 0
    return
  fi
  local count=0
  local IFS=','
  # Build a grep alternation
  local alternation=""
  for k in $kinds_csv; do
    if [ -n "$alternation" ]; then
      alternation="${alternation}|"
    fi
    alternation="${alternation}\"kind\":\"${k}\""
  done
  IFS=' '
  # Grep matching lines, count those with ts >= cutoff.
  while IFS= read -r line; do
    # Extract ts field — naive but works since ts is first key.
    local ts_str
    ts_str="$(printf '%s' "$line" | grep -oE '"ts":"[^"]+"' | head -1 | cut -d'"' -f4)"
    [ -z "$ts_str" ] && continue
    local ts_epoch
    if command -v gdate >/dev/null 2>&1; then
      ts_epoch="$(gdate -u -d "$ts_str" +%s 2>/dev/null || echo 0)"
    else
      # macOS BSD date: -j -f format
      ts_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_str" +%s 2>/dev/null || echo 0)"
    fi
    if [ "$ts_epoch" -ge "$CUTOFF_EPOCH" ]; then
      count=$((count + 1))
    fi
  done < <(grep -E "$alternation" "$AMBIENT_PATH" 2>/dev/null || true)
  echo "$count"
}

# Parse expectations.yaml — minimal parser, format is fixed.
# Output one record per daemon: daemon|expected_kinds_csv|min_per_hour|eligibility
parse_expectations() {
  local cur_daemon=""
  local cur_kinds=""
  local cur_min=""
  local cur_elig=""
  local in_kinds=0
  while IFS= read -r line; do
    # Strip CR + trailing spaces.
    line="${line%$'\r'}"
    case "$line" in
      "  - daemon: "*)
        # Flush prior record.
        if [ -n "$cur_daemon" ]; then
          printf '%s|%s|%s|%s\n' "$cur_daemon" "$cur_kinds" "$cur_min" "$cur_elig"
        fi
        cur_daemon="${line#"  - daemon: "}"
        cur_kinds=""
        cur_min="1"
        cur_elig="true"
        in_kinds=0
        ;;
      "    expected_kinds:"*)
        in_kinds=1
        ;;
      "      - "*)
        if [ "$in_kinds" = "1" ]; then
          local k="${line#"      - "}"
          if [ -n "$cur_kinds" ]; then
            cur_kinds="${cur_kinds},${k}"
          else
            cur_kinds="$k"
          fi
        fi
        ;;
      "    min_per_hour: "*)
        cur_min="${line#"    min_per_hour: "}"
        in_kinds=0
        ;;
      "    eligibility: "*)
        cur_elig="${line#"    eligibility: "}"
        # Strip quotes.
        cur_elig="${cur_elig#\"}"
        cur_elig="${cur_elig%\"}"
        in_kinds=0
        ;;
      "    description:"*)
        in_kinds=0
        ;;
    esac
  done < "$EXPECTATIONS"
  # Flush last record.
  if [ -n "$cur_daemon" ]; then
    printf '%s|%s|%s|%s\n' "$cur_daemon" "$cur_kinds" "$cur_min" "$cur_elig"
  fi
}

# Check if a daemon is LOADED.
daemon_is_loaded() {
  local label="$1"
  if [ -z "$LAUNCHCTL_OUT" ]; then
    # Can't check; assume eligible (test env).
    return 0
  fi
  echo "$LAUNCHCTL_OUT" | grep -qE "[[:space:]]${label}([[:space:]]|$)"
}

# Main loop.
silent_count=0
while IFS='|' read -r daemon kinds min_per_hour eligibility; do
  [ -z "$daemon" ] && continue
  # Convert min_per_hour to a count scaled to the actual window.
  # If window=3600 then min_per_hour=min count. If window != 3600, scale.
  local_min=$min_per_hour
  if [ "$WINDOW_SECS" -ne 3600 ]; then
    local_min=$(( (min_per_hour * WINDOW_SECS + 3599) / 3600 ))
    [ "$local_min" -lt 1 ] && local_min=1
  fi

  loaded="yes"
  if ! daemon_is_loaded "$daemon"; then
    loaded="no"
  fi

  # Eligibility — for now, "true" means always eligible; anything else
  # we evaluate as a shell expression (caller responsible for safety).
  eligible="yes"
  if [ "$eligibility" != "true" ] && [ -n "$eligibility" ]; then
    if ! eval "$eligibility" >/dev/null 2>&1; then
      eligible="no"
    fi
  fi

  if [ "$loaded" = "no" ]; then
    echo "[daemon-silence-monitor] skip $daemon: not LOADED" >&2
    continue
  fi
  if [ "$eligible" = "no" ]; then
    echo "[daemon-silence-monitor] skip $daemon: not eligible (no work to do)" >&2
    continue
  fi

  count="$(count_recent_kinds "$kinds")"
  if [ "$count" -lt "$local_min" ]; then
    diag="LOADED but emitted $count of expected kinds [$kinds] in last ${WINDOW_SECS}s (min=$local_min)"
    emit_ambient "daemon_silent" "$daemon" "$kinds" "$count" "$diag"
    silent_count=$((silent_count + 1))
  else
    echo "[daemon-silence-monitor] ok $daemon: $count emissions (min=$local_min)" >&2
  fi
done < <(parse_expectations)

# Always emit a tick — keeps THIS daemon visible to its own monitor.
emit_ambient "daemon_silence_monitor_tick" "self" "" "$silent_count" "scanned daemons"

exit 0
