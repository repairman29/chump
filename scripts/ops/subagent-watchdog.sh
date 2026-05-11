#!/usr/bin/env bash
# subagent-watchdog.sh — INFRA-334: monitor subagent heartbeat events in
# ambient.jsonl and emit ALERT kind=subagent_silent if a subagent goes silent.
#
# Subagents (chump --execute-gap) emit kind=subagent_heartbeat every 300s
# (configurable via CHUMP_SUBAGENT_HEARTBEAT_SECS). This watchdog checks
# for staleness and alerts when a gap_id's heartbeat is older than
# SUBAGENT_SILENT_TIMEOUT_S (default 900s = 3× heartbeat interval).
#
# Usage:
#   scripts/ops/subagent-watchdog.sh
#   REPO_ROOT=/path/to/repo scripts/ops/subagent-watchdog.sh
#
# Env:
#   REPO_ROOT            (default: git root) where to find ambient.jsonl
#   SUBAGENT_SILENT_TIMEOUT_S (default: 900) max age before alert

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SUBAGENT_SILENT_TIMEOUT_S="${SUBAGENT_SILENT_TIMEOUT_S:-900}"

_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
[[ -f "$_amb" ]] || exit 0

now=$(date +%s)

# Parse ambient.jsonl for subagent_heartbeat lines, track latest ts per gap_id.
declare -A latest_ts
declare -A latest_session

while IFS= read -r line; do
    kind=$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.readline()); print(d.get('kind',''))" 2>/dev/null || true)
    [[ "$kind" != "subagent_heartbeat" ]] && continue
    gap_id=$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.readline()); print(d.get('gap_id',''))" 2>/dev/null || true)
    ts_str=$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.readline()); print(d.get('ts',''))" 2>/dev/null || true)
    session=$(echo "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.readline()); print(d.get('session',''))" 2>/dev/null || true)

    [[ -z "$gap_id" || -z "$ts_str" ]] && continue

    ts_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_str" +%s 2>/dev/null || \
               date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts_str" +%s 2>/dev/null || \
               date -d "$ts_str" +%s 2>/dev/null || true)
    [[ -z "$ts_epoch" ]] && continue

    # Keep the latest ts for each gap_id.
    if [[ -z "${latest_ts[$gap_id]:-}" ]] || [[ $ts_epoch -gt ${latest_ts[$gap_id]} ]]; then
        latest_ts[$gap_id]=$ts_epoch
        latest_session[$gap_id]=$session
    fi
done < "$_amb"

# Check staleness for all active gap_ids.
_emitted=false
for gap_id in "${!latest_ts[@]}"; do
    age=$(( now - latest_ts[$gap_id] ))
    if [[ $age -gt $SUBAGENT_SILENT_TIMEOUT_S ]]; then
        session="${latest_session[$gap_id]:-}"
        _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"event":"ALERT","kind":"subagent_silent","ts":"%s","gap_id":"%s","session":"%s","age_seconds":%d,"subagent_silent_timeout_s":%d,"hint":"subagent for gap %s has not emitted heartbeat in %d seconds; likely hung or crashed"}\n' \
            "$_ts" "$gap_id" "$session" "$age" "$SUBAGENT_SILENT_TIMEOUT_S" "$gap_id" "$age" \
            >> "$_amb" 2>/dev/null || true
        _emitted=true
    fi
done

if $_emitted; then
    echo "[subagent-watchdog] ALERT: one or more subagents silent — check ambient.jsonl for subagent_silent events"
fi
