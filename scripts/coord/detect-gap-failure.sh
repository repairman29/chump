#!/usr/bin/env bash
# detect-gap-failure.sh — INFRA-872 (detection-only scope)
#
# Scans for gaps that look stuck and emits structured kind=gap_failed events
# so an operator (or follow-up auto-rollback in INFRA-889) can act.
#
# Detection rules:
#   1. STUCK LEASE: .chump-locks/claim-<gap>-*.json taken > CHUMP_STUCK_LEASE_S
#      seconds ago AND no commit on chump/<gap-lower>-claim since heartbeat.
#   2. STUCK PR: gh pr open > CHUMP_STUCK_PR_S seconds with failing checks
#      and no new commits.
#
# Each detection emits one ambient event with a failure-class taxonomy:
#   transient   — likely network/rate-limit; safe for auto-retry
#   code_quality — failing checks, needs human review
#   stalled     — no progress on lease for >2h; needs operator decision
#   infra       — bot-merge or CI infrastructure failure
#
# Auto-rollback EXECUTION is intentionally OUT OF SCOPE here; INFRA-889
# consumes the gap_failed events and decides recovery. This script only
# detects + classifies.
#
# Usage:
#   scripts/coord/detect-gap-failure.sh             # scan + emit events
#   scripts/coord/detect-gap-failure.sh --json      # also print findings as JSON
#   scripts/coord/detect-gap-failure.sh --dry-run   # detect but do not emit
#
# Env:
#   CHUMP_AMBIENT_LOG      ambient.jsonl path
#   CHUMP_STUCK_LEASE_S    seconds; default 7200 (2h)
#   CHUMP_STUCK_PR_S       seconds; default 7200 (2h)
#   CHUMP_DETECT_DRY_RUN=1 suppress emission

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_SCRIPT_DIR/../.." && pwd)}"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LOCKS_DIR="${CHUMP_LOCKS_DIR:-$REPO_ROOT/.chump-locks}"
STUCK_LEASE_S="${CHUMP_STUCK_LEASE_S:-7200}"
STUCK_PR_S="${CHUMP_STUCK_PR_S:-7200}"
DRY_RUN="${CHUMP_DETECT_DRY_RUN:-0}"
EMIT_JSON=0
# INFRA-1888: set to 1 to emit gap_failed even for status=done gaps (debug mode).
INCLUDE_DONE="${CHUMP_DETECT_GAP_FAILURE_INCLUDE_DONE:-0}"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --json)    EMIT_JSON=1 ;;
    --include-done) INCLUDE_DONE=1 ;;
  esac
done

_emit() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  local kind="$1"; shift
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"%s",%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$*" \
    >> "$AMBIENT" 2>/dev/null || true
}

# INFRA-1888: Returns 0 (true) if gap is status=open in state.db, 1 otherwise.
# When INCLUDE_DONE=1, always returns 0 (bypass mode).
_gap_is_open() {
  local gap_id="$1"
  [[ "$INCLUDE_DONE" == "1" ]] && return 0
  local db="$REPO_ROOT/.chump/state.db"
  [[ -f "$db" ]] || return 0  # no DB → assume open to avoid false negatives
  local status
  status=$(python3 -c "
import sqlite3, sys
try:
    conn = sqlite3.connect('$db')
    row = conn.execute('SELECT status FROM gaps WHERE id=?', ('$gap_id',)).fetchone()
    print(row[0] if row else 'open')
except Exception:
    print('open')
")
  [[ "$status" == "open" ]]
}

_age_seconds() {
  local ts="$1"
  [[ -z "$ts" ]] && { echo 999999; return; }
  python3 -c "
import datetime
try:
    t = datetime.datetime.strptime('$ts', '%Y-%m-%dT%H:%M:%SZ')
    delta = datetime.datetime.utcnow() - t
    print(int(delta.total_seconds()))
except Exception:
    print(999999)
"
}

# Findings buffer for --json output.
findings_json=""

add_finding() {
  local gap_id="$1" class="$2" reason="$3" recovery="$4" age_s="$5"
  # INFRA-1888: skip gaps that are no longer open (done/merged/wontfix) to
  # eliminate ~30% false-positive noise from already-shipped gaps.
  if ! _gap_is_open "$gap_id"; then
    return 0
  fi
  local f="{\"gap_id\":\"$gap_id\",\"class\":\"$class\",\"reason\":\"$reason\",\"recovery_action\":\"$recovery\",\"age_s\":$age_s}"
  if [[ -z "$findings_json" ]]; then
    findings_json="$f"
  else
    findings_json="$findings_json,$f"
  fi
  _emit "gap_failed" \
    "\"gap_id\":\"$gap_id\",\"class\":\"$class\",\"reason\":\"$reason\",\"recovery_action\":\"$recovery\",\"age_s\":$age_s,\"detector\":\"detect-gap-failure\""
  echo "FAIL [$class]: $gap_id — $reason (recovery: $recovery, age: ${age_s}s)"
}

# ── Scan 1: stuck leases ─────────────────────────────────────────────────────
scan_stuck_leases() {
  [[ -d "$LOCKS_DIR" ]] || return 0
  local lease_file
  for lease_file in "$LOCKS_DIR"/claim-*.json; do
    [[ -f "$lease_file" ]] || continue
    local gap_id taken_at heartbeat_at age_s
    gap_id=$(python3 -c "
import json
try: print(json.load(open('$lease_file')).get('gap_id', ''))
except: print('')
")
    [[ -z "$gap_id" ]] && continue
    taken_at=$(python3 -c "
import json
try: print(json.load(open('$lease_file')).get('taken_at', ''))
except: print('')
")
    heartbeat_at=$(python3 -c "
import json
try: print(json.load(open('$lease_file')).get('heartbeat_at', ''))
except: print('')
")
    # Use heartbeat if present, else taken_at.
    local effective_ts="${heartbeat_at:-$taken_at}"
    age_s=$(_age_seconds "$effective_ts")
    if [[ "$age_s" -lt "$STUCK_LEASE_S" ]]; then
      continue
    fi
    # Lease is old. Has the branch had commits since heartbeat?
    local branch="chump/$(echo "$gap_id" | tr '[:upper:]' '[:lower:]')-claim"
    local last_commit_ts=""
    if command -v git &>/dev/null; then
      last_commit_ts=$(git -C "$REPO_ROOT" log -1 --format='%cI' "origin/$branch" 2>/dev/null || echo "")
    fi
    # If no branch or last commit older than heartbeat → stalled.
    if [[ -z "$last_commit_ts" || "$last_commit_ts" < "$effective_ts" ]]; then
      add_finding "$gap_id" "stalled" \
        "lease taken ${age_s}s ago; no commit on branch since heartbeat" \
        "manual_review" "$age_s"
    fi
  done
}

# ── Scan 2: stuck open PRs ───────────────────────────────────────────────────
scan_stuck_prs() {
  command -v gh &>/dev/null || return 0
  # gh outputs JSON; jq optional — use python3 parser for portability.
  local prs_json
  prs_json=$(gh pr list --state open --limit 30 \
    --json number,title,updatedAt,statusCheckRollup,headRefName 2>/dev/null || echo "[]")
  python3 -c "
import json, sys, datetime, re, os
try:
    prs = json.loads('''$prs_json''')
except Exception:
    sys.exit(0)
stuck_s = int(os.environ.get('CHUMP_STUCK_PR_S', '7200'))
now = datetime.datetime.utcnow()
for p in prs:
    try:
        updated = datetime.datetime.fromisoformat(p['updatedAt'].replace('Z','+00:00')).replace(tzinfo=None)
    except Exception:
        continue
    age_s = int((now - updated).total_seconds())
    if age_s < stuck_s:
        continue
    rollup = p.get('statusCheckRollup', '')
    if rollup not in ('FAILURE', 'ERROR'):
        continue
    # Derive gap_id from branch name (chump/<gap>-claim) or title (PREFIX-NNN).
    branch = p.get('headRefName', '') or ''
    m = re.search(r'chump/([a-z]+-\d+)', branch)
    gap_id = m.group(1).upper() if m else ''
    if not gap_id:
        m = re.search(r'\b([A-Z]+-\d+)\b', p.get('title','') or '')
        gap_id = m.group(1) if m else 'UNKNOWN'
    print(f'PR_STUCK|{gap_id}|{age_s}|{rollup}|{p[\"number\"]}')
" | while IFS='|' read -r tag gap_id age_s rollup pr_num; do
    [[ "$tag" == "PR_STUCK" ]] || continue
    add_finding "$gap_id" "code_quality" \
      "PR #$pr_num open ${age_s}s with rollup=$rollup" \
      "manual_review" "$age_s"
  done
}

# ── Main ─────────────────────────────────────────────────────────────────────
# INFRA-1888: audit trail when bypass mode is active (must come after _emit def).
if [[ "$INCLUDE_DONE" == "1" ]]; then
  _emit "detect_gap_failure_lax" \
    "\"reason\":\"CHUMP_DETECT_GAP_FAILURE_INCLUDE_DONE=1 — done gaps included in scan\""
fi

scan_stuck_leases
scan_stuck_prs

if [[ "$EMIT_JSON" == "1" ]]; then
  echo "{\"findings\":[$findings_json]}"
fi

# Exit 0 always — detection is informational. INFRA-889 acts on the events.
exit 0
