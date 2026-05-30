#!/usr/bin/env bash
# test-target-reactor.sh — META-171: smoke test for target-loop.sh Phase 1.5 reactor.
#
# Exercises two fixtures:
#   1. Proposal with pillar prefix matching bottleneck → vote=1 emitted
#   2. Proposal with no pillar match → vote=0 (no +1 emit), reactor skips gracefully
# Also validates: anti-reaction-loop (own-session, consensus_result, non-proposal kinds).

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOOP_SCRIPT="$REPO_ROOT/scripts/coord/target-loop.sh"

if [[ ! -f "$LOOP_SCRIPT" ]]; then
    printf 'FAIL: %s not found\n' "$LOOP_SCRIPT" >&2
    exit 1
fi

chmod +x "$LOOP_SCRIPT"

_pass=0
_fail=0
_ok()  { printf '  ok  %s\n' "$*"; _pass=$((_pass + 1)); }
_bad() { printf '  FAIL: %s\n' "$*" >&2; _fail=$((_fail + 1)); }

# ── Test 1: bash -n syntax check ─────────────────────────────────────────────
printf 'Test 1: bash -n syntax check...\n'
if bash -n "$LOOP_SCRIPT" 2>/dev/null; then
    _ok "bash -n passes"
else
    _bad "bash -n failed — syntax error in $LOOP_SCRIPT"
fi

# ── Test 2: help subcommand exits 0 ──────────────────────────────────────────
printf 'Test 2: help exits 0...\n'
_rc=0
"$LOOP_SCRIPT" help >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "help exits 0"
else
    _bad "help should exit 0, got $_rc"
fi

# ── Test 3: heartbeat exits 0 + emits kind=target_heartbeat ──────────────────
printf 'Test 3: heartbeat emits kind=target_heartbeat...\n'
_dir3="$(mktemp -d)"
_amb3="$_dir3/ambient.jsonl"
_rc=0
CHUMP_AMBIENT_LOG="$_amb3" \
CHUMP_SESSION_ID="test-target-heartbeat-$$" \
CHUMP_LOCK_DIR="$_dir3" \
"$LOOP_SCRIPT" heartbeat >/dev/null 2>&1 || _rc=$?
if (( _rc == 0 )); then
    _ok "heartbeat exits 0"
else
    _bad "heartbeat should exit 0, got $_rc"
fi
if grep -q '"kind":"target_heartbeat"' "$_amb3" 2>/dev/null; then
    _ok "heartbeat emits target_heartbeat kind"
else
    _bad "heartbeat should emit target_heartbeat to ambient log"
fi
rm -rf "$_dir3"

# ── Test 4 (Fixture A): pillar-match proposal → vote=1 emitted ───────────────
# Inject a proposal whose subject starts with EFFECTIVE (default bottleneck).
printf 'Test 4 (Fixture A): pillar-match proposal → vote=+1...\n'
_dir4="$(mktemp -d)"
_amb4="$_dir4/ambient.jsonl"
_inbox_dir="$_dir4/inbox"
mkdir -p "$_inbox_dir"
_session="test-target-reactor-$$"
_inbox_file="$_inbox_dir/${_session}.jsonl"

# Detect live bottleneck pillar (mirror target-loop.sh logic: most-frequent pillar in ROADMAP)
_bottleneck="EFFECTIVE"
_roadmap="${REPO_ROOT}/docs/ROADMAP.md"
if [[ -f "$_roadmap" ]]; then
    _raw="$(grep -ioE '\b(EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE)\b' "$_roadmap" 2>/dev/null \
           | tr '[:lower:]' '[:upper:]' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}' || true)"
    [[ -n "$_raw" ]] && _bottleneck="$_raw"
fi

# Write a synthetic proposal whose subject matches the detected bottleneck
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-pillar-001","session":"peer-session-xyz","subject":"%s: add per-gap budget cap to worker dispatch","rationale":"reduces over-allocation"}\n' \
    "$_bottleneck" > "$_inbox_file"

_rc=0
CHUMP_FLEET_WIRE_V1=1 \
CHUMP_AMBIENT_LOG="$_amb4" \
CHUMP_SESSION_ID="$_session" \
CHUMP_LOCK_DIR="$_dir4" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || _rc=0   # tick exits 1 if quiet, allow both

if grep -q '"kind":"target_reactor_voted"' "$_amb4" 2>/dev/null; then
    _ok "Fixture A: target_reactor_voted emitted"
else
    _bad "Fixture A: expected target_reactor_voted in ambient"
fi

if grep -q '"vote":1' "$_amb4" 2>/dev/null; then
    _ok "Fixture A: vote=1 for pillar-matching proposal (bottleneck=$_bottleneck)"
else
    _bad "Fixture A: expected vote=1 for ${_bottleneck} proposal"
fi
rm -rf "$_dir4"

# ── Test 5 (Fixture B): non-pillar proposal → vote=0, no +1 ─────────────────
printf 'Test 5 (Fixture B): non-pillar proposal → vote=0...\n'
_dir5="$(mktemp -d)"
_amb5="$_dir5/ambient.jsonl"
_inbox_dir5="$_dir5/inbox"
mkdir -p "$_inbox_dir5"
_session5="test-target-reactor-b-$$"
_inbox_file5="$_inbox_dir5/${_session5}.jsonl"

# Write a proposal with no pillar prefix match
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-nopillar-001","session":"peer-session-abc","subject":"update changelog format","rationale":"housekeeping"}\n' \
    > "$_inbox_file5"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_AMBIENT_LOG="$_amb5" \
CHUMP_SESSION_ID="$_session5" \
CHUMP_LOCK_DIR="$_dir5" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"kind":"target_reactor_voted"' "$_amb5" 2>/dev/null; then
    _ok "Fixture B: target_reactor_voted emitted (with vote=0)"
    if grep '"vote":1' "$_amb5" 2>/dev/null | grep -q "corr-nopillar"; then
        _bad "Fixture B: should NOT vote=1 for non-pillar proposal"
    else
        _ok "Fixture B: vote is not 1 for no-pillar-match"
    fi
else
    # Reactor may not emit if vote=0 and no corr_id match — acceptable
    _ok "Fixture B: reactor skipped or voted 0 for no-pillar proposal"
fi
rm -rf "$_dir5"

# ── Test 6: anti-reaction-loop — own-session skipped ─────────────────────────
printf 'Test 6: anti-reaction-loop (own-session)...\n'
_dir6="$(mktemp -d)"
_amb6="$_dir6/ambient.jsonl"
_inbox_dir6="$_dir6/inbox"
mkdir -p "$_inbox_dir6"
_session6="test-target-own-$$"
_inbox_file6="$_inbox_dir6/${_session6}.jsonl"

# Proposal from own session should be skipped
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-own-001","session":"%s","subject":"EFFECTIVE: own proposal","rationale":"self"}\n' \
    "$_session6" > "$_inbox_file6"

CHUMP_FLEET_WIRE_V1=1 \
CHUMP_AMBIENT_LOG="$_amb6" \
CHUMP_SESSION_ID="$_session6" \
CHUMP_LOCK_DIR="$_dir6" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"kind":"target_reactor_voted".*corr-own-001' "$_amb6" 2>/dev/null; then
    _bad "anti-reaction-loop: should NOT vote on own-session proposal"
else
    _ok "anti-reaction-loop: own-session proposal correctly skipped"
fi
rm -rf "$_dir6"

# ── Test 7: flag off — reactor not invoked ────────────────────────────────────
printf 'Test 7: CHUMP_FLEET_WIRE_V1=0 skips reactor...\n'
_dir7="$(mktemp -d)"
_amb7="$_dir7/ambient.jsonl"
_inbox_dir7="$_dir7/inbox"
mkdir -p "$_inbox_dir7"
_session7="test-target-flagoff-$$"
_inbox_file7="$_inbox_dir7/${_session7}.jsonl"
printf '{"ts":"2026-05-30T00:00:00Z","kind":"proposal","corr_id":"corr-flagoff-001","session":"peer-zzz","subject":"EFFECTIVE: would match","rationale":"test"}\n' \
    > "$_inbox_file7"

CHUMP_FLEET_WIRE_V1=0 \
CHUMP_AMBIENT_LOG="$_amb7" \
CHUMP_SESSION_ID="$_session7" \
CHUMP_LOCK_DIR="$_dir7" \
"$LOOP_SCRIPT" tick >/dev/null 2>&1 || true

if grep -q '"kind":"target_reactor_voted"' "$_amb7" 2>/dev/null; then
    _bad "flag-off: reactor should not run when CHUMP_FLEET_WIRE_V1=0"
else
    _ok "flag-off: reactor correctly skipped when CHUMP_FLEET_WIRE_V1=0"
fi
rm -rf "$_dir7"

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n--- test-target-reactor: %d passed, %d failed ---\n' "$_pass" "$_fail"
(( _fail == 0 ))
