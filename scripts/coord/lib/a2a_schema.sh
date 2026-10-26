#!/usr/bin/env bash
# scripts/coord/lib/a2a_schema.sh — INFRA-1948
#
# Shared schema validator + lifecycle event helper for agent-to-agent (A2A)
# inbox messages.
#
# Required JSON fields on every A2A message: from, to, ts, kind, body.
# Emits kind=a2a_msg_schema_violation on invalid payloads and returns 1.
# Also provides a2a_emit_lifecycle for a2a_msg_sent, a2a_msg_delivered,
# a2a_msg_acked, and a2a_msg_dead_lettered.
#
# scanner-anchor: "kind":"a2a_msg_schema_violation"
# scanner-anchor: "kind":"a2a_msg_sent"
# scanner-anchor: "kind":"a2a_msg_delivered"
# scanner-anchor: "kind":"a2a_msg_acked"
# scanner-anchor: "kind":"a2a_msg_dead_lettered"
# scanner-anchor: "kind":"inbox_watcher_missing"
# scanner-anchor: "kind":"inbox_watcher_opted_out"
set -euo pipefail

a2a_validate_message_json() {
    local raw_json="${1:-}"
    local ambient_file="${AMBIENT_JSONL:-${CHUMP_LOCK_DIR:-.chump-locks}/ambient.jsonl}"
    python3 - "$raw_json" "$ambient_file" <<'PY'
import datetime
import json
import os
import sys

raw, ambient_file = sys.argv[1], sys.argv[2]
required = ("from", "to", "ts", "kind", "body")
missing: list[str] = []
reason = ""

try:
    obj = json.loads(raw)
    if not isinstance(obj, dict):
        reason = "not_a_json_object"
    else:
        for k in required:
            v = obj.get(k)
            if v is None or (isinstance(v, str) and not v.strip()):
                missing.append(k)
        if missing:
            reason = "missing_required_fields"
except Exception as exc:
    reason = f"invalid_json:{exc.__class__.__name__}"

if reason:
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    os.makedirs(os.path.dirname(ambient_file) or ".", exist_ok=True)
    ev = {
        "ts": ts,
        "kind": "a2a_msg_schema_violation",
        "event": "a2a_msg_schema_violation",
        "reason": reason,
        "missing_fields": missing,
    }
    with open(ambient_file, "a", encoding="utf-8") as af:
        af.write(json.dumps(ev, separators=(",", ":")) + "\n")
    sys.exit(1)

sys.exit(0)
PY
}

a2a_emit_lifecycle() {
    local stage="${1:-sent}"
    local msg_id="${2:-}"
    local sender="${3:-}"
    local recipient="${4:-}"
    local ambient_file="${AMBIENT_JSONL:-${CHUMP_LOCK_DIR:-.chump-locks}/ambient.jsonl}"
    local kind="a2a_msg_${stage}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$ambient_file")"
    printf '{"ts":"%s","kind":"%s","event":"%s","msg_id":"%s","from":"%s","to":"%s"}\n' \
        "$ts" "$kind" "$kind" "$msg_id" "$sender" "$recipient" >> "$ambient_file"
}
