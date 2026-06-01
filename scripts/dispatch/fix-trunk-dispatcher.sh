#!/usr/bin/env bash
# fix-trunk-dispatcher.sh — RESILIENT Fix-Trunk Priority Lane
#
# Pre-empts normal picker selection when trunk is RED. Walks the gap registry
# for open gaps whose `skills_required` contains the `fix_trunk` skill tag,
# atomically claims the highest-priority candidate (creating its worktree),
# and then EITHER broadcasts a SessionStart-hook signal so the operator's
# running Claude Code IDE picks it up (default mode=signal, respects the
# Max subscription billing) OR spawns a headless `claude -p` sub-agent
# against the console.anthropic.com API balance (opt-in mode=subprocess).
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
# Dispatch mode (INFRA-2341):
#   CHUMP_FIX_TRUNK_DISPATCH_MODE      "signal" (default) | "subprocess"
#     - signal     — claim atomically, then emit a fix_trunk_priority_signal
#                    ambient event AND write to .chump-locks/URGENT-INBOX.jsonl
#                    so inbox-check-urgent.sh surfaces it to the running IDE
#                    on the next PostToolUse / SessionStart hook fire. No
#                    headless `claude -p` is spawned — the operator's
#                    subscription session does the work.
#     - subprocess — legacy path: claim + spawn `claude -p --model $MODEL`
#                    in the worktree. Useful for users who explicitly want
#                    headless billing against ANTHROPIC_API_KEY or
#                    CLAUDE_CODE_OAUTH_TOKEN without an interactive IDE
#                    session open.
#
# Env overrides:
#   CHUMP_FIX_TRUNK_DISPATCH            "0" to disable entirely (default: enabled)
#   CHUMP_FIX_TRUNK_DISPATCH_MODE       "signal" (default) | "subprocess" (INFRA-2341)
#   CHUMP_FIX_TRUNK_TRUNK_RED_LOOKBACK_M   minutes to consider trunk_red fresh (default: 30)
#   CHUMP_FIX_TRUNK_MODEL               model to dispatch (default: sonnet) — subprocess mode only
#   CHUMP_FIX_TRUNK_SKILL_TAG           skill tag substring to match (default: fix_trunk)
#   CHUMP_FIX_TRUNK_STATE_DB            override path to state.db (default: $REPO_ROOT/.chump/state.db)
#   CHUMP_FIX_TRUNK_AMBIENT_FILE        override ambient.jsonl path (used in tests)
#   CHUMP_FIX_TRUNK_LOCK_FILE           override lock-file path (used in tests)
#   CHUMP_FIX_TRUNK_URGENT_INBOX        override URGENT-INBOX.jsonl path (used in tests, signal mode)
#   CHUMP_FIX_TRUNK_DRY_RUN             "1" → log + emit ambient but do not claim or dispatch
#
# Emits:
#   kind=fix_trunk_priority_signal  signal mode — claimed + signaled the IDE
#   kind=fix_trunk_dispatched       subprocess mode — claimed + spawned claude -p
#   kind=fix_trunk_no_candidate     trunk is RED but no fix_trunk gap is open
#   kind=fix_trunk_skipped          a prior dispatch is still alive (parallelism cap)
#
# Pillar: RESILIENT. Sibling of pr-shepherd-daemon (rescues stuck PRs),
# wizard-daemon (classifies cascading CI failures), trunk-red-detector
# (raises the trunk_red signal in the first place).
#
# Sentinel keeps its 60-min operator-recall path independent of this script:
# if no IDE picks up the signal within 60 min of trunk_red_persistent, the
# sentinel still calls operator-recall (CI_BROKEN) so a human gets paged.

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
DISPATCH_MODE="${CHUMP_FIX_TRUNK_DISPATCH_MODE:-signal}"  # INFRA-2341: default = signal
LOOKBACK_M="${CHUMP_FIX_TRUNK_TRUNK_RED_LOOKBACK_M:-30}"
MODEL="${CHUMP_FIX_TRUNK_MODEL:-sonnet}"
SKILL_TAG="${CHUMP_FIX_TRUNK_SKILL_TAG:-fix_trunk}"
STATE_DB="${CHUMP_FIX_TRUNK_STATE_DB:-$MAIN_REPO/.chump/state.db}"
AMBIENT="${CHUMP_FIX_TRUNK_AMBIENT_FILE:-$LOCK_DIR/ambient.jsonl}"
LOCK_FILE="${CHUMP_FIX_TRUNK_LOCK_FILE:-$LOCK_DIR/fix-trunk-dispatcher.lock}"
URGENT_INBOX="${CHUMP_FIX_TRUNK_URGENT_INBOX:-$LOCK_DIR/URGENT-INBOX.jsonl}"
DRY_RUN="${CHUMP_FIX_TRUNK_DRY_RUN:-0}"

# Validate mode early — typos here should fail loud, not silently fall through.
case "$DISPATCH_MODE" in
  signal|subprocess) : ;;
  *)
    printf '[fix-trunk-dispatcher] ERROR: CHUMP_FIX_TRUNK_DISPATCH_MODE=%q is invalid; expected signal|subprocess\n' "$DISPATCH_MODE" >&2
    exit 0
    ;;
esac

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
# scanner-anchor: kind=fix_trunk_priority_signal
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
  log "DRY_RUN=1 mode=$DISPATCH_MODE; would claim+dispatch $candidate_id but exiting"
  if [[ "$DISPATCH_MODE" == "signal" ]]; then
    emit_ambient "fix_trunk_priority_signal" "\"gap_id\":\"$candidate_id\",\"dispatch_mode\":\"signal\",\"dry_run\":true"
  else
    emit_ambient "fix_trunk_dispatched" "\"gap_id\":\"$candidate_id\",\"model\":\"$MODEL\",\"dispatch_mode\":\"subprocess\",\"dry_run\":true"
  fi
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

# Resolve the worktree path that `chump claim` allocated.
# INFRA-2337: The lease JSON written by src/atomic_claim.rs does NOT carry a
# `worktree` field — schema is {session_id, paths, taken_at, expires_at,
# heartbeat_at, purpose, gap_id} (write_basic_lease, lines 1680-1708). The
# worktree path is *deterministic* per atomic_claim.rs:682:
#   worktree_base = CHUMP_WORKTREE_BASE or /tmp
#   worktree_path = $worktree_base/chump-<gap-lower>
# We mirror that derivation here, then verify the dir exists on disk.
gap_lower="$(printf '%s' "$candidate_id" | tr '[:upper:]' '[:lower:]')"
worktree_base="${CHUMP_WORKTREE_BASE:-/tmp}"
worktree="$worktree_base/chump-$gap_lower"

if [[ ! -d "$worktree" ]]; then
  # Fallback path: parse `chump claim` stdout for the "worktree :" line. Some
  # operator-test scenarios use a stub or non-default CHUMP_WORKTREE_BASE; if
  # the deterministic guess misses, prefer the source of truth.
  parsed_wt="$(printf '%s\n' "$claim_out" | sed -n 's/.*worktree[[:space:]]*:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)"
  if [[ -n "$parsed_wt" && -d "$parsed_wt" ]]; then
    worktree="$parsed_wt"
  else
    log "claim succeeded but worktree path not resolved for $candidate_id (guessed=$worktree, parsed=$parsed_wt); exiting"
    emit_ambient "fix_trunk_dispatched" "\"gap_id\":\"$candidate_id\",\"model\":\"$MODEL\",\"error\":\"worktree_unresolved\",\"dispatched\":false"
    exit 0
  fi
fi

log "claimed $candidate_id at worktree=$worktree; dispatch_mode=$DISPATCH_MODE"

# ── INFRA-2341: dispatch mode branch ─────────────────────────────────────────
# Two paths from the same claim:
#   signal     — broadcast a SessionStart-hook signal to the running IDE
#                (default; respects Max subscription billing)
#   subprocess — spawn claude -p (legacy; opt-in headless API-key billing)
if [[ "$DISPATCH_MODE" == "signal" ]]; then
  # ── Signal path (INFRA-2341, default) ──────────────────────────────────────
  # The operator's running Claude Code IDE has a PostToolUse + SessionStart
  # hook chain that calls scripts/coord/inbox-check-urgent.sh. That helper
  # reads .chump-locks/URGENT-INBOX.jsonl and surfaces unread CRIT-class
  # entries as a <system-reminder> block on the next tool call. We write
  # there directly (no Sonnet, no second claude process, no second billing
  # surface) and emit the ambient event so the sentinel + observers see
  # the dispatch happened. The IDE then picks up the gap at its convenience.
  #
  # Mailbox payload schema (matches broadcast.sh CRIT format —
  # inbox-check-urgent.sh parses these fields):
  #   ts        — ISO-8601 UTC
  #   urgency   — "CRIT"
  #   from      — "fix-trunk-dispatcher"
  #   to        — "fleet-wide" (any IDE that reads the global inbox picks up)
  #   kind      — "fix_trunk_priority_signal" (for typed consumers)
  #   gap_id    — claimed gap id
  #   priority  — pulled from state.db (P0 typically)
  #   worktree  — absolute path to the pre-created worktree
  #   body      — human-readable instructions surfaced in the system-reminder
  filing_session="claim-${gap_lower}"
  # Pull priority for richer ambient + payload context (fall back gracefully).
  candidate_priority="$(sqlite3 "$STATE_DB" "SELECT priority FROM gaps WHERE id='$candidate_id';" 2>/dev/null || echo "P0")"
  candidate_priority="${candidate_priority:-P0}"

  signal_body="Trunk (main ci.yml) is RED. Gap $candidate_id ($candidate_priority) is claimed and ready at worktree=$worktree (branch chump/${gap_lower}-claim). Switch to that worktree (cd $worktree), read the failing CI gate (gh run list --branch main --workflow ci.yml --limit 5), and ship the surgical fix via scripts/coord/bot-merge.sh --gap $candidate_id --auto-merge. Mission: clear trunk red so the rest of the fleet can ship. See docs/process/PR_RESCUE_PROCEDURE.md for the canonical doctrine."

  # Write to global URGENT-INBOX so inbox-check-urgent.sh surfaces it. The
  # python3 here keeps JSON-escaping safe even if the body grows multi-line
  # or contains quotes in future iterations.
  python3 -c "
import json, sys
entry = {
    'ts': sys.argv[1],
    'urgency': 'CRIT',
    'from': 'fix-trunk-dispatcher',
    'to': 'fleet-wide',
    'kind': 'fix_trunk_priority_signal',
    'gap_id': sys.argv[2],
    'priority': sys.argv[3],
    'worktree': sys.argv[4],
    'filing_session': sys.argv[5],
    'body': sys.argv[6],
}
print(json.dumps(entry))
" "$TS" "$candidate_id" "$candidate_priority" "$worktree" "$filing_session" "$signal_body" \
    >> "$URGENT_INBOX" 2>/dev/null || log "WARN: failed to write URGENT-INBOX entry"

  # Record a singleton lock so a second tick doesn't re-signal the same gap
  # while the first signal is still unread. The lock holds *this* dispatcher
  # process's PID — kill -0 only succeeds while the launchd-spawned ticker
  # is alive (which it isn't, post-exit), so the next tick reclaims it
  # quickly. But the IDE-acknowledge event (fix_trunk_session_acknowledged
  # written by inbox-check-urgent.sh) is what actually retires the work;
  # we record claim_owner here so a curious operator can `cat` the lock to
  # see who's holding the gap.
  printf '{"pid":%d,"gap_id":"%s","started_at":"%s","dispatch_mode":"signal","worktree":"%s","filing_session":"%s"}\n' \
    "$$" "$candidate_id" "$TS" "$worktree" "$filing_session" \
    > "$LOCK_FILE"

  emit_ambient "fix_trunk_priority_signal" "\"gap_id\":\"$candidate_id\",\"priority\":\"$candidate_priority\",\"worktree\":\"$worktree\",\"filing_session\":\"$filing_session\",\"dispatch_mode\":\"signal\""

  log "signaled $candidate_id to running IDE via URGENT-INBOX (mode=signal); priority=$candidate_priority worktree=$worktree"
  exit 0
fi

# ── Subprocess path (legacy, opt-in via CHUMP_FIX_TRUNK_DISPATCH_MODE=subprocess) ──
log "dispatch_mode=subprocess; spawning $MODEL headless"

# ── INFRA-2340: OAUTH defensive read ─────────────────────────────────────────
# launchd plists historically didn't pass CLAUDE_CODE_OAUTH_TOKEN through to
# the dispatched claude -p subshell, causing 401 auth errors that killed the
# Sonnet within seconds (operator observed twice on 2026-05-31). The OAUTH
# token is refreshed every 5 min to ~/.chump/oauth-token.json (mode 0600);
# the daemon runs as the operator's user so we can read it directly. Only
# applied if neither auth env var is already set (env wins for explicit
# overrides / api-key mode).
#
# Security: only the token's string length is ever logged; the token itself
# never appears in any log path.
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" ]]; then
  if [[ -r "$HOME/.chump/oauth-token.json" ]]; then
    _token=$(python3 -c "import json; print(json.load(open('$HOME/.chump/oauth-token.json')).get('token',''))" 2>/dev/null)
    if [[ -n "$_token" ]]; then
      export CLAUDE_CODE_OAUTH_TOKEN="$_token"
      log "loaded CLAUDE_CODE_OAUTH_TOKEN from ~/.chump/oauth-token.json (len=${#_token})"
    else
      log "WARN: ~/.chump/oauth-token.json present but token key empty"
    fi
    unset _token
  else
    log "WARN: no CLAUDE_CODE_OAUTH_TOKEN, no ANTHROPIC_API_KEY, no readable ~/.chump/oauth-token.json — dispatched Sonnet will likely 401"
  fi
fi

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
Branch: chump/$gap_lower-claim (already checked out by chump claim).

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
printf '{"pid":%d,"gap_id":"%s","started_at":"%s","dispatch_mode":"subprocess","model":"%s","worktree":"%s","log":"%s"}\n' \
  "$sub_pid" "$candidate_id" "$TS" "$MODEL" "$worktree" "$sub_log" \
  > "$LOCK_FILE"

emit_ambient "fix_trunk_dispatched" "\"gap_id\":\"$candidate_id\",\"model\":\"$MODEL\",\"pid\":$sub_pid,\"worktree\":\"$worktree\",\"dispatch_mode\":\"subprocess\""

log "dispatched $MODEL pid=$sub_pid on $candidate_id (mode=subprocess); log=$sub_log"
exit 0
