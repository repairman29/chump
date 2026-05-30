#!/usr/bin/env bash
# test-shepherd-reactor.sh — META-171: smoke test for opus-shepherd-triage.sh Phase 1.5 reactor.
#
# Exercises two fixtures:
#   A. Proposal rationale contains a known VOA-001 wedge class → vote=+1
#   B. Proposal uses "new wedge rescue" phrasing with no known class → vote=-1
# Also validates: anti-reaction-loop guards, cooldown, flag-off.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TRIAGE_SCRIPT="$REPO_ROOT/scripts/coord/opus-shepherd-triage.sh"

if [[ ! -f "$TRIAGE_SCRIPT" ]]; then
    printf 'FAIL: %s not found\n' "$TRIAGE_SCRIPT" >&2
    exit 1
fi

chmod +x "$TRIAGE_SCRIPT"

_pass=0
_fail=0
_ok()  { printf '  ok  %s\n' "$*"; _pass=$((_pass + 1)); }
_bad() { printf '  FAIL: %s\n' "$*" >&2; _fail=$((_fail + 1)); }

# ── Test 1: bash -n syntax check ─────────────────────────────────────────────
printf 'Test 1: bash -n syntax check...\n'
if bash -n "$TRIAGE_SCRIPT" 2>/dev/null; then
    _ok "bash -n passes"
else
    _bad "bash -n failed — syntax error in $TRIAGE_SCRIPT"
fi

# ── Test 2: heartbeat subcommand exits 0 ─────────────────────────────────────
printf 'Test 2: heartbeat exits 0...\n'
_dir2="$(mktemp -d)"
_amb2="$_dir2/ambient.jsonl"
_rc=0
CHUMP_AMBIENT_LOG="$_amb2" \
CHUMP_SESSION_ID="test-shepherd-heartbeat-$$" \
CHUMP_OPUS_SHEPHERD_TRIAGE=0 \
"$TRIAGE_SCRIPT" heartbeat >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "heartbeat exits 0"
else
    _bad "heartbeat should exit 0, got $_rc"
fi
rm -rf "$_dir2"

# ── Fixture A: wedge-class match → vote=+1 ───────────────────────────────────
# Uses CHUMP_OPUS_SHEPHERD_TRIAGE=0 to skip the full Python triage body and
# exercise only the Phase 1.5 reactor injected in the 'tick' path.
printf 'Test 3 (Fixture A): wedge-class match → vote=+1...\n'
_dir3="$(mktemp -d)"
_amb3="$_dir3/ambient.jsonl"
_inbox_dir3="$_dir3/inbox"
mkdir -p "$_inbox_dir3"
_session3="test-shepherd-reactor-a-$$"
_inbox_file3="$_inbox_dir3/${_session3}.jsonl"

# Inject proposal whose rationale mentions a known wedge class (fmt-drift)
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-wedge-001","session":"peer-aaa","subject":"fix cargo fmt drift in CI","rationale":"fmt-drift causes repeated CI failures on fmt check step"}\n' \
    > "$_inbox_file3"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_OPUS_SHEPHERD_TRIAGE=0 \
CHUMP_AMBIENT_LOG="$_amb3" \
CHUMP_SESSION_ID="$_session3" \
CHUMP_LOCK_DIR="$_dir3" \
"$TRIAGE_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"kind":"shepherd_reactor_voted"' "$_amb3" 2>/dev/null; then
    _ok "Fixture A: shepherd_reactor_voted emitted"
else
    _bad "Fixture A: expected shepherd_reactor_voted in ambient"
fi

if grep -q '"vote":1' "$_amb3" 2>/dev/null; then
    _ok "Fixture A: vote=+1 for fmt-drift wedge class match"
else
    _bad "Fixture A: expected vote=1 for fmt-drift proposal"
fi
rm -rf "$_dir3"

# ── Fixture B: reinvents-wedge-rescue → vote=-1 ──────────────────────────────
printf 'Test 4 (Fixture B): reinvents-wedge-rescue → vote=-1...\n'
_dir4="$(mktemp -d)"
_amb4="$_dir4/ambient.jsonl"
_inbox_dir4="$_dir4/inbox"
mkdir -p "$_inbox_dir4"
_session4="test-shepherd-reactor-b-$$"
_inbox_file4="$_inbox_dir4/${_session4}.jsonl"

# Proposal that claims to invent a new wedge rescue but matches no known class
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-reinvent-001","session":"peer-bbb","subject":"new wedge rescue pattern for slow builds","rationale":"reinvent wedge rescue mechanism from scratch"}\n' \
    > "$_inbox_file4"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_OPUS_SHEPHERD_TRIAGE=0 \
CHUMP_AMBIENT_LOG="$_amb4" \
CHUMP_SESSION_ID="$_session4" \
CHUMP_LOCK_DIR="$_dir4" \
"$TRIAGE_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"kind":"shepherd_reactor_voted"' "$_amb4" 2>/dev/null; then
    _ok "Fixture B: shepherd_reactor_voted emitted"
else
    _bad "Fixture B: expected shepherd_reactor_voted in ambient"
fi

if grep -q '"vote":-1' "$_amb4" 2>/dev/null; then
    _ok "Fixture B: vote=-1 for reinvents-existing-wedge-rescue"
else
    _bad "Fixture B: expected vote=-1 for reinvented rescue proposal"
fi
rm -rf "$_dir4"

# ── Test 5: anti-reaction-loop — own-session skipped ─────────────────────────
printf 'Test 5: anti-reaction-loop (own-session)...\n'
_dir5="$(mktemp -d)"
_amb5="$_dir5/ambient.jsonl"
_inbox_dir5="$_dir5/inbox"
mkdir -p "$_inbox_dir5"
_session5="test-shepherd-own-$$"
_inbox_file5="$_inbox_dir5/${_session5}.jsonl"

printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-own-002","session":"%s","subject":"fmt-drift fix","rationale":"fmt-drift self-proposal"}\n' \
    "$_session5" > "$_inbox_file5"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_OPUS_SHEPHERD_TRIAGE=0 \
CHUMP_AMBIENT_LOG="$_amb5" \
CHUMP_SESSION_ID="$_session5" \
CHUMP_LOCK_DIR="$_dir5" \
"$TRIAGE_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"corr_id":"corr-own-002"' "$_amb5" 2>/dev/null; then
    _bad "anti-reaction-loop: should NOT vote on own-session proposal"
else
    _ok "anti-reaction-loop: own-session proposal correctly skipped"
fi
rm -rf "$_dir5"

# ── Test 6: non-proposal kind skipped ────────────────────────────────────────
printf 'Test 6: non-proposal kind (vote) skipped...\n'
_dir6="$(mktemp -d)"
_amb6="$_dir6/ambient.jsonl"
_inbox_dir6="$_dir6/inbox"
mkdir -p "$_inbox_dir6"
_session6="test-shepherd-nonprop-$$"
_inbox_file6="$_inbox_dir6/${_session6}.jsonl"

printf '{"ts":"2026-05-30T00:00:00Z","kind":"vote","corr_id":"corr-vote-001","session":"peer-ccc","subject":"fmt-drift","rationale":"fmt-drift"}\n' \
    > "$_inbox_file6"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_OPUS_SHEPHERD_TRIAGE=0 \
CHUMP_AMBIENT_LOG="$_amb6" \
CHUMP_SESSION_ID="$_session6" \
CHUMP_LOCK_DIR="$_dir6" \
"$TRIAGE_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"corr_id":"corr-vote-001"' "$_amb6" 2>/dev/null; then
    _bad "anti-reaction-loop: should NOT react to kind=vote events"
else
    _ok "anti-reaction-loop: kind=vote correctly ignored"
fi
rm -rf "$_dir6"

# ── Test 7: flag off — reactor skipped ───────────────────────────────────────
printf 'Test 7: CHUMP_FLEET_WIRE_V1=0 skips reactor...\n'
_dir7="$(mktemp -d)"
_amb7="$_dir7/ambient.jsonl"
_inbox_dir7="$_dir7/inbox"
mkdir -p "$_inbox_dir7"
_session7="test-shepherd-flagoff-$$"
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-flagoff-002","session":"peer-ddd","subject":"fmt-drift fix","rationale":"fmt-drift"}\n' \
    > "$_inbox_dir7/${_session7}.jsonl"

CHUMP_FLEET_WIRE_V1=0 \
CHUMP_OPUS_SHEPHERD_TRIAGE=0 \
CHUMP_AMBIENT_LOG="$_amb7" \
CHUMP_SESSION_ID="$_session7" \
CHUMP_LOCK_DIR="$_dir7" \
"$TRIAGE_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"kind":"shepherd_reactor_voted"' "$_amb7" 2>/dev/null; then
    _bad "flag-off: reactor should not run when CHUMP_FLEET_WIRE_V1=0"
else
    _ok "flag-off: reactor correctly skipped when CHUMP_FLEET_WIRE_V1=0"
fi
rm -rf "$_dir7"

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n--- test-shepherd-reactor: %d passed, %d failed ---\n' "$_pass" "$_fail"
(( _fail == 0 ))
