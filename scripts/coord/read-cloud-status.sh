#!/usr/bin/env bash
# read-cloud-status.sh — RESILIENT-1466: read cloud-agent status.
# Replays the CLOUD JetStream stream when nats+CHUMP_NATS_URL are available,
# else falls back to ~/.chump/cloud-status.jsonl. Usage: read-cloud-status.sh [N=20]
set -euo pipefail
n="${1:-20}"
url="${CHUMP_NATS_URL:-${NATS_URL:-}}"
if command -v nats >/dev/null 2>&1 && [[ -n "$url" ]] \
   && nats --server "$url" stream info CLOUD >/dev/null 2>&1; then
  last="$(nats --server "$url" stream info CLOUD --json 2>/dev/null | sed -n 's/.*"last_seq": *\([0-9]*\).*/\1/p' | head -1)"
  last="${last:-0}"
  start=$(( last - n + 1 )); (( start < 1 )) && start=1
  for ((s=start; s<=last; s++)); do
    nats --server "$url" stream get CLOUD "$s" --json 2>/dev/null \
      | sed -n 's/.*"data": *"\([^"]*\)".*/\1/p' | base64 -d 2>/dev/null; echo
  done | sed '/^$/d'
else
  f="$HOME/.chump/cloud-status.jsonl"
  [[ -f "$f" ]] && tail -n "$n" "$f" || echo "(no cloud status yet)"
fi
