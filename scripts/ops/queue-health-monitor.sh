#!/usr/bin/env bash
# queue-health-monitor.sh — INFRA-052
#
# Hourly check for known queue/agent failure modes that otherwise sit
# silently for hours. Writes JSONL to .chump/health.jsonl (one record
# per check pass) plus a human-readable alerts log at .chump/alerts.log.
#
# Detects:
#   1. PRs OPEN > 45 min with non-passing required checks (BLOCKED/DIRTY/BEHIND).
#   2. Active session leases > 90 min since last commit by that session.
#   3. Linked worktrees > 5 GB (target/ bloat — disk pressure precursor).
#
# Designed to be quiet on a healthy queue (single "ok" line in health.jsonl)
# and noisy on a sick one (alerts.log gets ALERT lines + ambient.jsonl
# gets one ALERT event per finding so sibling agents see it in their
# next FLEET-019 SessionStart digest).
#
# Usage:
#   scripts/ops/queue-health-monitor.sh             # live run
#   scripts/ops/queue-health-monitor.sh --dry-run   # print findings; no jsonl/alerts/ambient writes
#   scripts/ops/queue-health-monitor.sh --quiet     # suppress stdout (launchd default)
#
# Environment:
#   QUEUE_HEALTH_PR_STUCK_MIN   minutes a PR can be OPEN+BLOCKED before alert
#                                (default: 45)
#   QUEUE_HEALTH_AGENT_SILENT_MIN  minutes a lease can have no commits before
#                                  alert (default: 90)
#   QUEUE_HEALTH_WORKTREE_MAX_GB worktree size in GB before alert (default: 5)
#   QUEUE_HEALTH_REPO            repo for gh pr list (default: derived from origin)
#
# Exit codes:
#   0  clean (no alerts) OR alerts found and written (script always succeeds
#      so launchd doesn't restart-spam)

set -euo pipefail

DRY_RUN=0
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

PR_STUCK_MIN="${QUEUE_HEALTH_PR_STUCK_MIN:-45}"
AGENT_SILENT_MIN="${QUEUE_HEALTH_AGENT_SILENT_MIN:-90}"
WORKTREE_MAX_GB="${QUEUE_HEALTH_WORKTREE_MAX_GB:-5}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
CHUMP_DIR="$MAIN_REPO/.chump"
HEALTH_JSONL="$CHUMP_DIR/health.jsonl"
ALERTS_LOG="$CHUMP_DIR/alerts.log"
EMIT="$MAIN_REPO/scripts/dev/ambient-emit.sh"

mkdir -p "$CHUMP_DIR"

say()  { [[ "$QUIET" -eq 1 ]] || printf '\033[1;36m[queue-health]\033[0m %s\n' "$*"; }
warn() { [[ "$QUIET" -eq 1 ]] || printf '\033[1;33m[queue-health]\033[0m %s\n' "$*" >&2; }

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"

ALERT_COUNT=0
ALERT_DETAILS=()

emit_alert() {
    local kind="$1"
    local msg="$2"
    ALERT_COUNT=$((ALERT_COUNT + 1))
    ALERT_DETAILS+=("$kind: $msg")
    if [[ "$DRY_RUN" -eq 1 ]]; then
        say "ALERT (dry-run) $kind: $msg"
        return 0
    fi
    printf '%s\t%s\t%s\n' "$TS" "$kind" "$msg" >> "$ALERTS_LOG"
    if [[ -x "$EMIT" ]]; then
        # Truncate long messages so a single alert doesn't blow the digest budget.
        local short="${msg:0:200}"
        "$EMIT" ALERT "kind=$kind" "note=$short" 2>/dev/null || true
    fi
}

# ── Check 1: stuck PRs ────────────────────────────────────────────────────────
if command -v gh >/dev/null; then
    say "checking PR queue (stuck > ${PR_STUCK_MIN} min, BLOCKED/DIRTY)..."
    # gh pr list --json gives us createdAt + mergeStateStatus; we just need
    # OPEN ones that are not MERGEABLE/CLEAN and have been around long enough.
    PR_JSON="$(gh pr list --state open --limit 50 --json number,title,createdAt,updatedAt,mergeStateStatus,autoMergeRequest 2>/dev/null || echo '[]')"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        emit_alert "pr_stuck" "$line"
    done < <(printf '%s' "$PR_JSON" | NOW_EPOCH="$NOW_EPOCH" STUCK_MIN="$PR_STUCK_MIN" python3 -c '
import json, os, sys
from datetime import datetime
data = json.loads(sys.stdin.read() or "[]")
now = int(os.environ["NOW_EPOCH"])
stuck_min = int(os.environ["STUCK_MIN"])
for pr in data:
    state = pr.get("mergeStateStatus") or "UNKNOWN"
    if state in ("CLEAN", "MERGEABLE", "UNKNOWN"):
        continue
    updated = pr.get("updatedAt") or pr.get("createdAt") or ""
    try:
        ts = datetime.fromisoformat(updated.replace("Z", "+00:00")).timestamp()
    except Exception:
        continue
    age_min = int((now - ts) / 60)
    if age_min < stuck_min:
        continue
    auto = (pr.get("autoMergeRequest") or {}).get("mergeMethod") or "off"
    title = (pr.get("title", "") or "")[:80]
    num = pr.get("number", "?")
    print("#{} {} auto={} age={}m {}".format(num, state, auto, age_min, title))
')
fi

# ── Check 2: silent agents (lease present, no recent commits) ────────────────
say "checking active leases for silent agents (no commits > ${AGENT_SILENT_MIN} min)..."
shopt -s nullglob
for lease in "$LOCK_DIR"/*.json; do
    sess_id="$(basename "$lease" .json)"
    [[ "$sess_id" == ".wt-session-id" ]] && continue
    # Lease taken_at is informational; what matters is "did this session commit anything recently?"
    # We approximate by greppping ambient.jsonl for the most recent commit/file_edit by this session.
    # If ambient has no entries for this session in the silent window, raise.
    if [[ -f "$LOCK_DIR/ambient.jsonl" ]]; then
        last_event_ts="$(grep -F "\"session\":\"$sess_id\"" "$LOCK_DIR/ambient.jsonl" 2>/dev/null \
            | tail -1 \
            | python3 -c "import json,sys; line=sys.stdin.read().strip(); print(json.loads(line).get('ts','')) if line else print('')" 2>/dev/null || true)"
    else
        last_event_ts=""
    fi
    if [[ -z "$last_event_ts" ]]; then
        # No ambient activity at all — measure from lease taken_at instead.
        last_event_ts="$(python3 -c "import json; print(json.load(open('$lease')).get('taken_at',''))" 2>/dev/null || true)"
    fi
    [[ -z "$last_event_ts" ]] && continue
    last_epoch="$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$last_event_ts'.replace('Z','+00:00')).timestamp()))" 2>/dev/null || echo 0)"
    [[ "$last_epoch" == 0 ]] && continue
    age_min=$(( (NOW_EPOCH - last_epoch) / 60 ))
    if (( age_min >= AGENT_SILENT_MIN )); then
        gap_id="$(python3 -c "import json; print(json.load(open('$lease')).get('gap_id','?'))" 2>/dev/null || echo '?')"
        emit_alert "silent_agent" "session=$sess_id gap=$gap_id last_event_age=${age_min}m"
    fi
done
shopt -u nullglob

# ── Check 3: fat worktrees ────────────────────────────────────────────────────
say "checking worktrees for size > ${WORKTREE_MAX_GB} GB..."
WT_PARENT_NEW="$MAIN_REPO/.chump/worktrees"
WT_PARENT_OLD="$MAIN_REPO/.claude/worktrees"
for parent in "$WT_PARENT_NEW" "$WT_PARENT_OLD"; do
    [[ -d "$parent" ]] || continue
    for wt in "$parent"/*/; do
        [[ -d "$wt" ]] || continue
        # du -sk gives KB; convert to GB.
        kb="$(du -sk "$wt" 2>/dev/null | awk '{print $1}')"
        [[ -z "$kb" ]] && continue
        gb=$(python3 -c "print(round($kb / 1024 / 1024, 2))" 2>/dev/null || echo 0)
        over=$(python3 -c "print(1 if $gb > $WORKTREE_MAX_GB else 0)" 2>/dev/null || echo 0)
        if [[ "$over" == "1" ]]; then
            emit_alert "fat_worktree" "path=${wt%/} size_gb=${gb} (run scripts/ops/stale-worktree-reaper.sh --execute or rm -rf <worktree>/target/)"
        fi
    done
done

# ── Write health.jsonl record ────────────────────────────────────────────────
# Pass alerts via env so we don't have to escape them through nested heredocs.
ALERTS_JOINED=""
if [[ "${#ALERT_DETAILS[@]}" -gt 0 ]]; then
    ALERTS_JOINED="$(printf '%s\n' "${ALERT_DETAILS[@]}")"
fi
RECORD="$(
    TS="$TS" \
    ALERT_COUNT="$ALERT_COUNT" \
    ALERTS_JOINED="$ALERTS_JOINED" \
    PR_STUCK_MIN="$PR_STUCK_MIN" \
    AGENT_SILENT_MIN="$AGENT_SILENT_MIN" \
    WORKTREE_MAX_GB="$WORKTREE_MAX_GB" \
    python3 -c '
import json, os
alerts_text = os.environ.get("ALERTS_JOINED", "")
alerts = [l.strip() for l in alerts_text.splitlines() if l.strip()]
print(json.dumps({
    "ts": os.environ["TS"],
    "alert_count": int(os.environ["ALERT_COUNT"]),
    "alerts": alerts,
    "thresholds": {
        "pr_stuck_min": int(os.environ["PR_STUCK_MIN"]),
        "agent_silent_min": int(os.environ["AGENT_SILENT_MIN"]),
        "worktree_max_gb": float(os.environ["WORKTREE_MAX_GB"]),
    },
}))
'
)"
if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s\n' "$RECORD" >> "$HEALTH_JSONL"
fi

if [[ "$ALERT_COUNT" -gt 0 ]]; then
    say "${ALERT_COUNT} alert(s) written to $ALERTS_LOG"
else
    say "ok — no alerts"
fi

exit 0
