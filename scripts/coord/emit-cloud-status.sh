#!/usr/bin/env bash
# emit-cloud-status.sh — RESILIENT-1466: cloud-agent status write-back.
# Publishes {ts,kind:"cloud_agent_status",agent,session,phase,task,summary} to
# NATS subject chump.cloud.status (durable via the CLOUD JetStream stream) and
# ALWAYS appends the same line to ~/.chump/cloud-status.jsonl.
# Usage: emit-cloud-status.sh <phase> <task> <summary> [agent] [session]
#   phase: start|working|blocked|shipped|done|error
set -euo pipefail
phase="${1:?phase (start|working|blocked|shipped|done|error)}"
task="${2:?task (gap-id or slug)}"
summary="${3:-}"
agent="${4:-${CHUMP_CLOUD_AGENT:-cloud-agent}}"
session="${5:-${CHUMP_SESSION_ID:-unknown}}"
case "$phase" in start|working|blocked|shipped|done|error) ;; *) echo "bad phase: $phase" >&2; exit 2;; esac
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t' '  '; }
line="$(printf '{"ts":"%s","kind":"cloud_agent_status","agent":"%s","session":"%s","phase":"%s","task":"%s","summary":"%s"}' \
  "$ts" "$(esc "$agent")" "$(esc "$session")" "$phase" "$(esc "$task")" "$(esc "$summary")")"
mkdir -p "$HOME/.chump"
printf '%s\n' "$line" >> "$HOME/.chump/cloud-status.jsonl"
url="${CHUMP_NATS_URL:-${NATS_URL:-}}"
if command -v nats >/dev/null 2>&1 && [[ -n "$url" ]]; then
  nats --server "$url" pub chump.cloud.status "$line" >/dev/null 2>&1 \
    || echo "emit-cloud-status: NATS publish failed (local jsonl still written)" >&2
fi
printf '%s\n' "$line"
