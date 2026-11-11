#!/usr/bin/env bash
# emit-cloud-status.sh — RESILIENT-1466: cloud-agent status write-back.
# Publishes {ts,kind:"cloud_agent_status",agent,session,phase,task,summary} to
# NATS subject chump.cloud.status (durable via the CLOUD JetStream stream) and
# ALWAYS appends the same line to ~/.chump/cloud-status.jsonl.
# Usage: emit-cloud-status.sh <phase> <task> <summary> [agent] [session]
#   phase: start|working|blocked|shipped|done|error
# Env: CHUMP_NATS_URL (default nats://127.0.0.1:4222), CLOUD_STATUS_FILE.
set -euo pipefail
phase="${1:?phase required (start|working|blocked|shipped|done|error)}"
task="${2:?task (gap-id or slug) required}"
summary="${3:-}"
agent="${4:-${CHUMP_CLOUD_AGENT:-cloud-agent}}"
session="${5:-${CHUMP_CLOUD_SESSION:-${CLAUDE_SESSION_ID:-unknown}}}"
case "$phase" in start|working|blocked|shipped|done|error) ;; *) echo "bad phase: $phase" >&2; exit 2;; esac
out="${CLOUD_STATUS_FILE:-$HOME/.chump/cloud-status.jsonl}"
mkdir -p "$(dirname "$out")"
payload="$(python3 - "$phase" "$task" "$summary" "$agent" "$session" <<'PY'
import json,sys,datetime
p,t,s,a,se=sys.argv[1:6]
print(json.dumps({"ts":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
 "kind":"cloud_agent_status","agent":a,"session":se,"phase":p,"task":t,"summary":s},separators=(",",":")))
PY
)"
printf '%s\n' "$payload" >> "$out"
if command -v nats >/dev/null 2>&1; then
  nats --server "${CHUMP_NATS_URL:-nats://127.0.0.1:4222}" pub chump.cloud.status "$payload" >/dev/null 2>&1 \
    || echo "emit-cloud-status: NATS publish failed (local jsonl still written)" >&2
else
  echo "emit-cloud-status: nats CLI absent (local jsonl still written)" >&2
fi
