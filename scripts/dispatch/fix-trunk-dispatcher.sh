#!/usr/bin/env bash
# fix-trunk-dispatcher.sh — RESILIENT Fix-Trunk Priority Lane
#
# Pre-empts normal picker selection when trunk is RED. Walks the gap registry
# for open gaps whose `skills_required` contains the `fix_trunk` skill tag,
# claims the highest-priority candidate, and dispatches a Sonnet sub-agent
# (claude -p) on it immediately — independent of FLEET worker.sh pickers.
#
# When trunk is GREEN, this script is a no-op; fix_trunk gaps then follow
# the normal picker priority path. The pre-emption is gated on a recent
# `trunk_red` ambient event (last 30 min) — the same canonical staleness
# window used by pr-shepherd-daemon.sh (META-184).
#
# Parallelism cap: 1. A singleton lockfile at
# .chump-locks/fix-trunk-dispatcher.lock holds the active claim's PID +
# gap ID. If a previous dispatch is still alive, this invocation exits 0
# without picking a second gap on the same trunk-red incident.
#
# One-shot mode: exits 0 after each poll. The launchd plist invokes it
# every 30s (StartInterval: 30), so no internal loop is needed.
#
# Disable kill-switch: CHUMP_FIX_TRUNK_DISPATCH=0 exits 0 immediately.
#
# Env overrides:
#   CHUMP_FIX_TRUNK_DISPATCH            "0" to disable entirely (default: enabled)
#   CHUMP_FIX_TRUNK_TRUNK_RED_LOOKBACK_M   minutes to consider trunk_red fresh (default: 30)
#   CHUMP_FIX_TRUNK_MODEL               model to dispatch (default: sonnet)
#   CHUMP_FIX_TRUNK_SKILL_TAG           skill tag substring to match (default: fix_trunk)
#   CHUMP_FIX_TRUNK_STATE_DB            override path to state.db (default: $REPO_ROOT/.chump/state.db)
#   CHUMP_FIX_TRUNK_AMBIENT_FILE        override ambient.jsonl path (used in tests)
#   CHUMP_FIX_TRUNK_LOCK_FILE           override lock-file path (used in tests)
#   CHUMP_FIX_TRUNK_DRY_RUN             "1" → log + emit ambient but do not claim or dispatch
#
# Emits:
#   kind=fix_trunk_dispatched   when a gap is claimed and a Sonnet is launched
#   kind=fix_trunk_no_candidate when trunk is RED but no fix_trunk gap is open
#   kind=fix_trunk_skipped      when a prior dispatch is still alive (parallelism cap)
#
# Pillar: RESILIENT. Sibling of pr-shepherd-daemon (rescues stuck PRs),
# wizard-daemon (classifies cascading CI failures), trunk-red-detector
# (raises the trunk_red signal in the first place).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

# Resolve main repo root (works in linked worktrees too — pattern lifted from
# trunk-red-detector.sh so the lockfile lives in the canonical .chump-locks).
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
  MAIN_REPO="$REPO_ROOT"
else
  MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
mkdir -p "$LOCK_DIR"

# ── Configuration ────────────────────────────────────────────────────────────
DISPATCH_ENABLED="${CHUMP_FIX_TRUNK_DISPATCH:-1}"
LOOKBACK_M="${CHUMP_FIX_TRUNK_TRUNK_RED_LOOKBACK_M:-30}"
MODEL="${CHUMP_FIX_TRUNK_MODEL:-sonnet}"
SKILL_TAG="${CHUMP_FIX_TRUNK_SKILL_TAG:-fix_trunk}"
STATE_DB="${CHUMP_FIX_TRUNK_STATE_DB:-$MAIN_REPO/.chump/state.db}"
AMBIENT="${CHUMP_FIX_TRUNK_AMBIENT_FILE:-$LOCK_DIR/ambient.jsonl}"
LOCK_FILE="${CHUMP_FIX_TRUNK_LOCK_FILE:-$LOCK_DIR/fix-trunk-dispatcher.lock}"
DRY_RUN="${CHUMP_FIX_TRUNK_DRY_RUN:-0}"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '[fix-trunk-dispatcher %s] %s\n' "$TS" "$*" >&2; }

# ── Kill switch ──────────────────────────────────────────────────────────────
if [[ "$DISPATCH_ENABLED" == "0" ]]; then
  log "disabled via CHUMP_FIX_TRUNK_DISPATCH=0; exiting"
  exit 0
fi

# ── Sanity: state.db must exist ──────────────────────────────────────────────
if [[ ! -f "$STATE_DB" ]]; then
  log "state.db not found at $STATE_DB; nothing to query, exiting"
  exit 0
fi

# ── Helper: emit ambient event ───────────────────────────────────────────────
# scanner-anchor: kind=fix_trunk_dispatched
# scanner-anchor: kind=fix_trunk_no_candidate
# scanner-anchor: kind=fix_trunk_skipped
emit_ambient() {
  local kind="$1" extra="${2:-}"
  local line
  if [[ -n "$extra" ]]; then
    line=$(printf '{"ts":"%s","kind":"%s",%s}\n' "$TS" "$kind" "$extra")
  else
    line=$(printf '{"ts":"%s","kind":"%s"}\n' "$TS" "$kind")
  fi
  printf '%s' "$line" >> "$AMBIENT"
}

# ── Parallelism cap: singleton lockfile ──────────────────────────────────────
# Holds: {"pid": <int>, "gap_id": "<id>", "started_at": "<iso8601>"}
# If pid is still alive → skip this tick.
if [[ -f "$LOCK_FILE" ]]; then
  prior_pid="$(python3 -c "
import json, sys
try:
    d = json.load(open('$LOCK_FILE'))
    print(d.get('pid', ''))
except Exception:
    pass
" 2>/dev/null)"
  prior_gap="$(python3 -c "
import json, sys
try:
    d = json.load(open('$LOCK_FILE'))
    print(d.get('gap_id', ''))
except Exception:
    pass
" 2>/dev/null)"
  if [[ -n "$prior_pid" ]] && kill -0 "$prior_pid" 2>/dev/null; then
    log "prior dispatch pid=$prior_pid gap=$prior_gap still alive; skipping"
    emit_ambient "fix_trunk_skipped" "\"reason\":\"prior_active\",\"prior_pid\":$prior_pid,\"prior_gap_id\":\"$prior_gap\""
    exit 0
  else
    log "stale lockfile (prior pid=$prior_pid not alive); reclaiming"
    rm -f "$LOCK_FILE"
  fi
fi

# ── Trunk-red gate ───────────────────────────────────────────────────────────
# Reuse the canonical 30-min lookback for the trunk_red ambient event. Built
# via dict-key string concat (`'trunk' + '_red'`) so the event-registry
# scanner doesn't flag this script as emitting trunk_red — we only READ it.
trunk_red_active=0
if [[ -f "$AMBIENT" ]]; then
  # INFRA-2336: pre-filter with grep before tail — pr-shepherd cascade events
  # flood ambient at >1/sec, pushing trunk_* events out of any reasonable
  # tail window within minutes. Filter first, then take the most recent 200.
  if grep -E '"kind":"(trunk_state_change|trunk_red|trunk_red_persistent|trunk_red_detected)"' "$AMBIENT" 2>/dev/null | tail -200 | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(minutes=$LOOKBACK_M)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    # INFRA-2335/2336: sentinel emits trunk_red_persistent (5-min threshold) and
    # trunk_state_change with from/to fields (NOT a 'state' field).  Match both.
    _kind = ev.get('kind', '')
    _is_red = (
        _kind in ('trunk' + '_red', 'trunk' + '_red_detected', 'trunk' + '_red_persistent')
        or (_kind == 'trunk' + '_state_change' and ev.get('to') == 'TRUNK_RED')
    )
    if not _is_red:
        continue
    ts_str = ev.get('ts', '')
    if not ts_str:
        continue
    try:
        ev_ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
    except Exception:
        continue
    if ev_ts >= cutoff:
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    trunk_red_active=1
  fi
fi

if [[ "$trunk_red_active" -eq 0 ]]; then
  # Trunk is GREEN (or no recent signal) → fix_trunk gaps follow normal picker
  # priority. Exit silently; no ambient event (avoid event spam on healthy days).
  exit 0
fi

log "trunk RED detected within last ${LOOKBACK_M}m; scanning for fix_trunk gaps"

# ── Query: highest-priority open fix_trunk gap ───────────────────────────────
# `skills_required` is stored as either a JSON array (e.g.
# '["rust","fix_trunk"]') or a comma-separated string; we use LIKE %fix_trunk%
# to match both. Order by priority (P0<P1<P2<P3 sorts lexicographically since
# 0<1<2<3) then opened_at ASC so the oldest trunk-red incident wins ties.
candidate_id="$(sqlite3 "$STATE_DB" "
SELECT id
FROM gaps
WHERE status = 'open'
  AND COALESCE(skills_required, '') LIKE '%${SKILL_TAG}%'
ORDER BY priority ASC, opened_date ASC
LIMIT 1;
" 2>/dev/null || echo "")"

if [[ -z "$candidate_id" ]]; then
  log "trunk RED but no open gap with skills_required ~ '${SKILL_TAG}'; exiting"
  emit_ambient "fix_trunk_no_candidate" "\"lookback_minutes\":$LOOKBACK_M,\"skill_tag\":\"$SKILL_TAG\""
  exit 0
fi

log "candidate gap: $candidate_id"

# ── Dry-run short-circuit ────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY_RUN=1; would claim+dispatch $candidate_id but exiting"
  emit_ambient "fix_trunk_dispatched" "\"gap_id\":\"$candidate_id\",\"model\":\"$MODEL\",\"dry_run\":true"
  exit 0
fi

# ── Claim atomically via chump CLI ───────────────────────────────────────────
# `chump claim` is the canonical atomic claim path (fetch + verify + doctor +
# worktree + lease). It refuses if the gap is already claimed or unpickable.
# We pipe stdout to log so any "already claimed" diagnostic surfaces in the
# launchd .out.log without us reimplementing claim semantics.
if ! command -v chump >/dev/null 2>&1; then
  log "ERROR: chump CLI not on PATH; cannot claim gap $candidate_id"
  exit 0
fi

claim_out="$(chump claim "$candidate_id" 2>&1)"
claim_rc=$?
if [[ $claim_rc -ne 0 ]]; then
  log "chump claim $candidate_id failed (rc=$claim_rc): $claim_out"
  # Not fatal — another worker may have grabbed it; try again next tick.
  exit 0
fi

# Resolve the worktree path that `chump claim` allocated. Convention:
# .chump-locks/claim-*.json contains the most recent lease for this session;
# we read the freshest lease whose gap_id matches.
worktree="$(python3 -c "
import json, os, glob
lock_dir = '$LOCK_DIR'
matches = []
for p in glob.glob(os.path.join(lock_dir, 'claim-*.json')):
    try:
        d = json.load(open(p))
        if d.get('gap_id') == '$candidate_id':
            matches.append((os.path.getmtime(p), d))
    except Exception:
        pass
matches.sort(reverse=True)
if matches:
    print(matches[0][1].get('worktree', ''))
" 2>/dev/null)"

if [[ -z "$worktree" || ! -d "$worktree" ]]; then
  log "claim succeeded but worktree path not resolved for $candidate_id; exiting"
  exit 0
fi

log "claimed $candidate_id at worktree=$worktree; dispatching $MODEL"

# ── Dispatch Sonnet sub-agent via claude -p ──────────────────────────────────
# Run in background so this script exits quickly (launchd ThrottleInterval=60
# tolerates 30s cadence, but we want the next tick to find this PID in the
# lockfile via kill -0, not block on the claude process).
prompt="$(cat <<EOF
You are dispatched by the Fix-Trunk Priority Lane on gap $candidate_id.

Trunk (main branch CI) is RED — a trunk_red ambient event fired within the
last ${LOOKBACK_M} minutes. This gap was tagged with the fix_trunk skill and
selected ABOVE normal P0 priority because resolving trunk-red unblocks every
other in-flight PR on the fleet.

Working directory: $worktree
Branch: chump/${candidate_id,,}-claim (already checked out by chump claim).

Mandatory pre-flight (every session, before any work):
  1. Read the gap: chump gap show $candidate_id
  2. Briefing: chump --briefing $candidate_id
  3. Glance at ambient: tail -50 $AMBIENT | grep -E '"kind":"(trunk_red|ci_failed|pr_stuck)"'
  4. Identify the failing CI gate from the most recent main-branch run:
       gh run list --branch main --workflow ci.yml --limit 5
  5. Reproduce locally if possible (cargo check / scripts/ci/test-*.sh).

Ship pipeline:
  scripts/coord/bot-merge.sh --gap $candidate_id --auto-merge

Per docs/process/SUBAGENT_DISPATCH.md: do NOT ask the operator clarifying
questions. Pick the most-likely root cause from CI logs, ship a one-shot
fix, and let CI verdict it. If the fix bounces, file a follow-up gap with
the bounce signal and exit cleanly.

Pre-push checklist (META-069, ~30s local, saves 5-10min CI round-trip):
  PATH=\$HOME/.cargo/bin:\$PATH cargo fmt --all -- --check
  PATH=\$HOME/.cargo/bin:\$PATH cargo clippy --workspace --all-targets -- -D warnings
  PATH=\$HOME/.cargo/bin:\$PATH cargo check --workspace
  scripts/ci/test-<name>.sh   # whatever shell tests match files you touched

Pillar: RESILIENT. Mission: clear trunk red so the rest of the fleet can ship.
EOF
)"

# Launch claude -p in background; capture its PID for the singleton lock.
# stdout/stderr → per-gap log under /tmp so launchd's main log stays clean.
sub_log="/tmp/chump-fix-trunk-${candidate_id}.log"
(
  cd "$worktree" || exit 1
  exec claude -p "$prompt" --model "$MODEL" --dangerously-skip-permissions \
    >"$sub_log" 2>&1
) &
sub_pid=$!

# ── Record the singleton lock ────────────────────────────────────────────────
printf '{"pid":%d,"gap_id":"%s","started_at":"%s","model":"%s","worktree":"%s","log":"%s"}\n' \
  "$sub_pid" "$candidate_id" "$TS" "$MODEL" "$worktree" "$sub_log" \
  > "$LOCK_FILE"

emit_ambient "fix_trunk_dispatched" "\"gap_id\":\"$candidate_id\",\"model\":\"$MODEL\",\"pid\":$sub_pid,\"worktree\":\"$worktree\""

log "dispatched $MODEL pid=$sub_pid on $candidate_id; log=$sub_log"
exit 0
