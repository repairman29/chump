#!/usr/bin/env bash
# cloud-status-audit.sh — RESILIENT-1466 AC7: exit 1 if JetStream is off, the
# CLOUD stream is missing, or chump-fleet-recorder is dark. Emits
# kind=cloud_status_decay to ambient on failure. Skip a probe: CLOUD_AUDIT_SKIP_RECORDER=1.
set -uo pipefail
url="${CHUMP_NATS_URL:-nats://127.0.0.1:4222}"
bad=()
if ! command -v nats >/dev/null 2>&1; then bad+=("nats-cli-missing")
elif ! nats --server "$url" account info 2>/dev/null | grep -qi 'JetStream'; then bad+=("jetstream-off")
elif ! nats --server "$url" stream info CLOUD >/dev/null 2>&1; then bad+=("cloud-stream-missing"); fi
if [ "${CLOUD_AUDIT_SKIP_RECORDER:-0}" != 1 ]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files chump-fleet-recorder.service 2>/dev/null | grep -q recorder; then
    systemctl is-active --quiet chump-fleet-recorder.service || bad+=("fleet-recorder-dark")
  elif command -v launchctl >/dev/null 2>&1; then
    launchctl list 2>/dev/null | grep -q com.chump.fleet-recorder || bad+=("fleet-recorder-dark")
  else bad+=("fleet-recorder-dark"); fi
fi
if [ ${#bad[@]} -gt 0 ]; then
  echo "cloud-status-audit: DECAY: ${bad[*]}" >&2
  amb="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
  [ -d "$(dirname "$amb")" ] && printf '{"ts":"%s","kind":"cloud_status_decay","reasons":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${bad[*]}" >> "$amb"
  exit 1
fi
echo "cloud-status-audit: OK"
