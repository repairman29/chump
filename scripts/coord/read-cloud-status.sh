#!/usr/bin/env bash
# read-cloud-status.sh — RESILIENT-1466: replay cloud-agent status from the
# CLOUD JetStream stream (no live subscriber needed). Falls back to the local
# ~/.chump/cloud-status.jsonl when NATS/nats CLI is unavailable.
# Usage: read-cloud-status.sh [N=20]
set -euo pipefail
n="${1:-20}"
url="${CHUMP_NATS_URL:-nats://127.0.0.1:4222}"
if command -v nats >/dev/null 2>&1 && nats --server "$url" stream info CLOUD >/dev/null 2>&1; then
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  last="$(nats --server "$url" stream info CLOUD --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"]["last_seq"])')"
  first=$(( last - n + 1 )); [ "$first" -lt 1 ] && first=1
  for ((i=first;i<=last;i++)); do
    nats --server "$url" stream get CLOUD "$i" --json 2>/dev/null \
      | python3 -c 'import sys,json,base64;print(base64.b64decode(json.load(sys.stdin)["data"]).decode())' 2>/dev/null || true
  done
else
  tail -n "$n" "${CLOUD_STATUS_FILE:-$HOME/.chump/cloud-status.jsonl}" 2>/dev/null || true
fi
