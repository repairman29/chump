#!/usr/bin/env bash
# INFRA-419 — flag (and best-effort kill) subagents that exceed budget
# without invoking bot-merge.sh.
#
# Background. META-025 measured subagent self-ship rate at 25-33%. Many
# failures are runaway loops — agent picks a gap, wanders for hours,
# never reaches the ship step. The Agent-tool's own timeout (4h) is too
# generous; this reaper bounds the worst case at CHUMP_SUBAGENT_BUDGET_MIN.
#
# What it does:
#   1. Walks .chump-locks/*.json for active leases.
#   2. For each, computes age = now - taken_at.
#   3. If age > BUDGET_MIN AND no commit/bot-merge ambient event from this
#      session_id since taken_at → emit ALERT kind=subagent_budget_exceeded.
#   4. Mark the lease file with `"budget_exceeded": true` so siblings can
#      see the agent is presumed-dead even if the file hasn't expired yet.
#   5. Best-effort kill via the lease's pid field (when present). Without
#      a tracked pid we can't terminate the subprocess; that's a known
#      limitation — see the TODO at the kill block.
#
# Designed to be safe to run anytime; runs every 5min via launchd.
# Bypass: CHUMP_SUBAGENT_REAPER=0.

set -euo pipefail

if [[ "${CHUMP_SUBAGENT_REAPER:-1}" == "0" ]]; then
    echo "[subagent-budget-reaper] CHUMP_SUBAGENT_REAPER=0 — bypass"
    exit 0
fi

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup subagent-budget
reaper_check_disk_headroom  # INFRA-453: exit 0 + ALERT if <5% free

BUDGET_MIN="${CHUMP_SUBAGENT_BUDGET_MIN:-30}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Note: reaper_setup unconditionally sets REAPER_LOCK_DIR=$REPO_ROOT/.chump-locks
# above, which is correct in production but overrides any caller-provided
# value. CHUMP_SUBAGENT_LOCK_DIR is a dedicated test-injection hook for
# scripts/ci/test-subagent-budget.sh — takes precedence when set so the
# fixture sandbox doesn't get bypassed.
LOCK_DIR="${CHUMP_SUBAGENT_LOCK_DIR:-${REAPER_LOCK_DIR:-$REPO_ROOT/.chump-locks}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

NOW_EPOCH=$(date -u +%s)
BUDGET_S=$(( BUDGET_MIN * 60 ))

REAPED=0
SCANNED=0

shopt -s nullglob
for lease in "$LOCK_DIR"/*.json; do
    SCANNED=$(( SCANNED + 1 ))

    # Skip leases that already have budget_exceeded marked.
    grep -q '"budget_exceeded"[[:space:]]*:[[:space:]]*true' "$lease" 2>/dev/null && continue

    # Read fields. Tolerate missing keys.
    sid=$(python3 -c "import json,sys;d=json.load(open('$lease'));print(d.get('session_id',''))" 2>/dev/null || echo "")
    gid=$(python3 -c "import json,sys;d=json.load(open('$lease'));print(d.get('gap_id',''))" 2>/dev/null || echo "")
    taken=$(python3 -c "import json,sys;d=json.load(open('$lease'));print(d.get('taken_at',''))" 2>/dev/null || echo "")
    pid=$(python3 -c "import json,sys;d=json.load(open('$lease'));print(d.get('pid',''))" 2>/dev/null || echo "")
    [[ -z "$sid" || -z "$taken" ]] && continue

    # Compute age.
    taken_epoch=$(python3 -c "
from datetime import datetime, timezone
import sys
try:
    t = datetime.fromisoformat('$taken'.replace('Z','+00:00'))
    print(int(t.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
    [[ "$taken_epoch" -eq 0 ]] && continue
    age_s=$(( NOW_EPOCH - taken_epoch ))
    [[ "$age_s" -lt "$BUDGET_S" ]] && continue

    # Check whether this session committed anything since taken_at —
    # commits AND bot-merge invocations both prove the agent is making
    # progress. Search the ambient stream for either signal.
    progressed=$(python3 -c "
import json, sys
sid = '$sid'
taken_epoch = $taken_epoch
try:
    with open('$AMBIENT') as f:
        for line in f:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get('session_id') != sid and rec.get('agent_id') != sid:
                continue
            ev = rec.get('event','') or rec.get('kind','')
            if ev in ('commit','bot_merge_start','bot_merge_done'):
                from datetime import datetime
                ts = rec.get('ts','')
                try:
                    e = int(datetime.fromisoformat(ts.replace('Z','+00:00')).timestamp())
                    if e > taken_epoch:
                        print('1'); sys.exit()
                except Exception:
                    pass
except FileNotFoundError:
    pass
print('0')
" 2>/dev/null || echo "0")
    if [[ "$progressed" == "1" ]]; then
        continue
    fi

    # Budget exceeded with no progress signal. Mark + alert.
    age_min=$(( age_s / 60 ))
    echo "[subagent-budget-reaper] BUDGET EXCEEDED: session=$sid gap=$gid age=${age_min}m (>${BUDGET_MIN}m budget)"

    # Mark lease as budget_exceeded.
    python3 -c "
import json
p = '$lease'
d = json.load(open(p))
d['budget_exceeded'] = True
d['budget_exceeded_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
json.dump(d, open(p,'w'), indent=2)
"

    # Emit ambient ALERT.
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"event":"alert","kind":"subagent_budget_exceeded","ts":"%s","agent_id":"%s","gap_id":"%s","age_min":%d,"budget_min":%d}\n' \
        "$ts" "$sid" "$gid" "$age_min" "$BUDGET_MIN" >> "$AMBIENT" 2>/dev/null || true

    # Best-effort kill via tracked pid.
    # TODO(INFRA-419 follow-up): leases don't reliably carry a pid today.
    # When chump dispatch / Agent-tool spawns track the subprocess pid into
    # the lease, this block becomes load-bearing. Until then, the ALERT +
    # budget_exceeded marker is the operator-visible signal.
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "[subagent-budget-reaper]   sending SIGTERM to pid $pid"
        kill -TERM "$pid" 2>/dev/null || true
    fi

    REAPED=$(( REAPED + 1 ))
done
shopt -u nullglob

echo "[subagent-budget-reaper] scanned=$SCANNED reaped=$REAPED budget=${BUDGET_MIN}m"
reaper_finish ok "{\"scanned\":$SCANNED,\"reaped\":$REAPED,\"budget_min\":$BUDGET_MIN}"
