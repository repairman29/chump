#!/usr/bin/env bash
# scanner-anchor: "kind":"jetstream_cloud_decay"
# jetstream-cloud-decay-audit.sh — RESILIENT-2227 (RESILIENT-1466 AC5/AC7)
#
# Flags silent decay of the cloud-agent write-back path: JetStream off, the
# CLOUD stream (chump.cloud.>) missing, or chump-fleet-recorder dark. Prints one
# line per check, exits 1 if any check fails, and (unless --no-emit) appends a
# kind=jetstream_cloud_decay ALERT to ambient.jsonl so the pager path sees it.
#
# Test seams: CHUMP_DECAY_NATS_BIN (nats CLI), CHUMP_DECAY_RECORDER_ACTIVE_CMD
# (exit 0 = recorder active), CHUMP_AMBIENT_LOG.
set -uo pipefail

EMIT=1
[ "${1:-}" = "--no-emit" ] && EMIT=0

NATS_BIN="${CHUMP_DECAY_NATS_BIN:-nats}"
NATS_URL="${CHUMP_NATS_URL:-nats://127.0.0.1:4222}"
AMBIENT="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
STREAM="${CHUMP_CLOUD_STREAM:-CLOUD}"

recorder_active() {
  if [ -n "${CHUMP_DECAY_RECORDER_ACTIVE_CMD:-}" ]; then
    bash -c "$CHUMP_DECAY_RECORDER_ACTIVE_CMD"
    return $?
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet chump-fleet-recorder.service 2>/dev/null; then
    return 0
  fi
  if command -v launchctl >/dev/null 2>&1 && launchctl list 2>/dev/null | grep -q 'com.chump.fleet-recorder'; then
    return 0
  fi
  pgrep -f chump-fleet-recorder >/dev/null 2>&1
}

failures=()

if ! command -v "$NATS_BIN" >/dev/null 2>&1 && [ ! -x "$NATS_BIN" ]; then
  echo "FAIL jetstream: nats CLI not found ($NATS_BIN) — cannot probe JetStream"
  failures+=("jetstream_unprobeable")
else
  if "$NATS_BIN" --server "$NATS_URL" account info 2>/dev/null | grep -qi 'JetStream.*\(not enabled\|disabled\)\|not enabled'; then
    echo "FAIL jetstream: JetStream is OFF on $NATS_URL"
    failures+=("jetstream_off")
  elif ! "$NATS_BIN" --server "$NATS_URL" account info >/dev/null 2>&1; then
    echo "FAIL jetstream: broker unreachable at $NATS_URL"
    failures+=("jetstream_unreachable")
  else
    echo "ok   jetstream: enabled"
    if "$NATS_BIN" --server "$NATS_URL" stream info "$STREAM" >/dev/null 2>&1; then
      echo "ok   cloud-stream: $STREAM present"
    else
      echo "FAIL cloud-stream: $STREAM missing (expected capture of chump.cloud.>)"
      failures+=("cloud_stream_missing")
    fi
  fi
fi

if recorder_active; then
  echo "ok   fleet-recorder: active"
else
  echo "FAIL fleet-recorder: dark (chump-fleet-recorder not running)"
  failures+=("fleet_recorder_dark")
fi

if [ "${#failures[@]}" -eq 0 ]; then
  exit 0
fi

if [ "$EMIT" -eq 1 ]; then
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null
  printf '{"ts":"%s","kind":"jetstream_cloud_decay","level":"ALERT","failed":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(IFS=,; echo "${failures[*]}")" >> "$AMBIENT"
fi
exit 1
