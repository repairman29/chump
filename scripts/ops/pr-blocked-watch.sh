#!/usr/bin/env bash
# pr-blocked-watch.sh — INFRA-550: emit kind=pr_blocked_long ALERT to
# ambient.jsonl for PRs with auto-merge armed, mergeStateStatus=BLOCKED,
# and at least one required check pending or failing for >BLOCKED_THRESHOLD_HOURS.
#
# Complements stuck-pr-filer (INFRA-307): whereas stuck-pr-filer files a
# cleanup gap (CI_RED condition, threshold 2h after completedAt), this script
# catches the slower "check is still PENDING / never finished" case earlier,
# emitting an ALERT so any session pre-flight sees it without gap clutter.
#
# Condition (all three must hold):
#   1. PR is open with auto-merge armed
#   2. mergeStateStatus=BLOCKED
#   3. updatedAt is >BLOCKED_THRESHOLD_HOURS ago AND at least one check
#      is PENDING, IN_PROGRESS, QUEUED, or FAILURE/ERROR/CANCELLED/TIMED_OUT
#
# Usage:
#   scripts/ops/pr-blocked-watch.sh              # live run
#   scripts/ops/pr-blocked-watch.sh --dry-run    # print what would be emitted
#
# Environment:
#   BLOCKED_THRESHOLD_HOURS   hours a BLOCKED+armed PR must sit (default: 2)
#   CHUMP_PR_BLOCKED_WATCH=0  bypass — exit 0 immediately
#
# Emits:
#   {"event":"ALERT","kind":"pr_blocked_long","ts":"...","pr":<N>,
#    "blocked_hours":<h>,"checks":["name1","name2"]}
#
# Heartbeat: /tmp/chump-reaper-pr-blocked.heartbeat
# Log: /tmp/chump-pr-blocked-watch.out.log

set -euo pipefail

if [[ "${CHUMP_PR_BLOCKED_WATCH:-1}" == "0" ]]; then
    echo "[pr-blocked-watch] CHUMP_PR_BLOCKED_WATCH=0 — bypass"
    exit 0
fi

# shellcheck source=../lib/reaper-instrumentation.sh
source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
reaper_setup pr-blocked
reaper_rotate_log /tmp/chump-pr-blocked-watch.out.log
reaper_rotate_log /tmp/chump-pr-blocked-watch.err.log
trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

BLOCKED_THRESHOLD_HOURS="${BLOCKED_THRESHOLD_HOURS:-2}"

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
info() { printf '  %s\n' "$*"; }
dry()  { printf '  [dry-run] %s\n' "$*"; }
warn() { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }

echo "[pr-blocked-watch] threshold=${BLOCKED_THRESHOLD_HOURS}h"
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no ambient events will be written."

# pr_age_hours ISO_TIMESTAMP — fractional hours between now and timestamp.
pr_age_hours() {
    local ts_val="$1"
    [[ -z "$ts_val" ]] && { echo 0; return; }
    python3 -c "
import sys
from datetime import datetime, timezone
try:
    t = datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00'))
    delta = datetime.now(timezone.utc) - t
    print(int(delta.total_seconds() / 3600))
except Exception:
    print(0)
" "$ts_val" 2>/dev/null || echo 0
}

AMBIENT="$REAPER_LOCK_DIR/ambient.jsonl"

emit_alert() {
    local pr_num="$1"
    local blocked_hours="$2"
    local checks_json="$3"   # JSON array string, e.g. '["ci/test","ci/lint"]'

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "ALERT pr_blocked_long: PR #${pr_num} BLOCKED ${blocked_hours}h — checks: ${checks_json}"
        return
    fi

    local event_ts
    event_ts="$(ts)"
    local json
    if command -v python3 >/dev/null 2>&1; then
        json=$(python3 -c "
import json, sys
print(json.dumps({
    'event': 'ALERT',
    'kind': 'pr_blocked_long',
    'ts': sys.argv[1],
    'pr': int(sys.argv[2]),
    'blocked_hours': int(sys.argv[3]),
    'checks': json.loads(sys.argv[4]),
}))
" "$event_ts" "$pr_num" "$blocked_hours" "$checks_json" 2>/dev/null || true)
    fi
    if [[ -z "$json" ]]; then
        json="{\"event\":\"ALERT\",\"kind\":\"pr_blocked_long\",\"ts\":\"${event_ts}\",\"pr\":${pr_num},\"blocked_hours\":${blocked_hours},\"checks\":${checks_json}}"
    fi
    mkdir -p "$REAPER_LOCK_DIR" 2>/dev/null || true
    printf '%s\n' "$json" >> "$AMBIENT" 2>/dev/null || true
    info "ALERT emitted: PR #${pr_num} BLOCKED ${blocked_hours}h — checks: ${checks_json}"
}

# 1. Fetch open PRs with auto-merge armed and BLOCKED merge state.
PRS_RAW="$(
    {
        gh pr list --state open --limit 100 \
            --json number,title,mergeStateStatus,autoMergeRequest,updatedAt \
            2>/dev/null || echo '[]'
    } | python3 -c '
import json, sys
try:
    prs = json.load(sys.stdin)
except Exception:
    prs = []
for p in prs:
    if p.get("mergeStateStatus") != "BLOCKED":
        continue
    if not p.get("autoMergeRequest"):
        continue
    n   = p["number"]
    upd = p.get("updatedAt") or ""
    tit = (p.get("title") or "").replace("\t", " ")
    print(f"{n}\t{upd}\t{tit}")
' 2>/dev/null
)" || PRS_RAW=""

SCANNED=0
ALERTED=0
SKIPPED=0

if [[ -z "$PRS_RAW" ]]; then
    info "No BLOCKED+armed open PRs found."
    reaper_finish ok '{"scanned":0,"alerted":0,"skipped":0}'
    trap - EXIT
    exit 0
fi

SCANNED=$(printf '%s\n' "$PRS_RAW" | wc -l | tr -d ' ')
echo "[pr-blocked-watch] found $SCANNED BLOCKED+armed PR(s)"

# 2. For each PR: check age, then fetch offending checks.
while IFS=$'\t' read -r PR_NUM UPDATED_AT PR_TITLE; do
    [[ -z "$PR_NUM" ]] && continue

    info "PR #${PR_NUM}  ${PR_TITLE}"

    AGE_HOURS=$(pr_age_hours "$UPDATED_AT")
    info "  blocked_hours=${AGE_HOURS} (threshold=${BLOCKED_THRESHOLD_HOURS})"

    if (( AGE_HOURS < BLOCKED_THRESHOLD_HOURS )); then
        info "  → under threshold, skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # 3. Identify offending checks (pending or failing).
    OFFENDING_CHECKS='[]'
    if command -v gh >/dev/null 2>&1; then
        CHECKS_JSON="$(gh pr checks "$PR_NUM" --json name,state 2>/dev/null || echo '[]')"
        OFFENDING_CHECKS="$(python3 -c "
import json, sys
try:
    rows = json.loads(sys.argv[1])
except Exception:
    rows = []
bad_states = {
    'PENDING', 'IN_PROGRESS', 'QUEUED',
    'FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED',
}
names = []
for r in rows:
    state = (r.get('state') or '').upper()
    if state in bad_states:
        names.append(r.get('name') or 'unknown')
print(json.dumps(names))
" "$CHECKS_JSON" 2>/dev/null || echo '[]')"
    fi

    # If no offending checks found (all checks passed but PR still BLOCKED),
    # still alert — the BLOCKED state itself is the signal.
    if [[ "$OFFENDING_CHECKS" == "[]" ]]; then
        OFFENDING_CHECKS='["(all-checks-green-but-blocked)"]'
    fi

    info "  offending checks: ${OFFENDING_CHECKS}"
    emit_alert "$PR_NUM" "$AGE_HOURS" "$OFFENDING_CHECKS"
    ALERTED=$((ALERTED + 1))
done <<< "$PRS_RAW"

echo "[pr-blocked-watch] done: scanned=${SCANNED} alerted=${ALERTED} skipped=${SKIPPED}"

trap - EXIT
reaper_finish ok "{\"scanned\":${SCANNED},\"alerted\":${ALERTED},\"skipped\":${SKIPPED}}"
