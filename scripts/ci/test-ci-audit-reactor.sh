#!/usr/bin/env bash
# scripts/ci/test-ci-audit-reactor.sh — META-169: Phase 1.5 reactor tests.
#
# 3 fixtures per AC #5:
#   Fixture A — regression_attributed proposal, high-confidence (suspect_commits=5) → vote +1
#   Fixture B — regression_attributed proposal, low-confidence (suspect_commits=1)  → vote 0
#   Fixture C — non-regression proposal (no regression_attributed ref)              → skip
#
# Also tests:
#   Anti-loop: kind=vote proposal → skip
#   Anti-loop: own-session proposal → skip
#   Anti-loop: consensus_result-fired corr_id → skip
#   Cooldown: second call within 30min → skip
#   Feature-flag: CHUMP_FLEET_WIRE_V1=0 → noop

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOOP_SCRIPT="$REPO_ROOT/scripts/coord/ci-audit-loop.sh"

if [[ ! -f "$LOOP_SCRIPT" ]]; then
    echo "FAIL: $LOOP_SCRIPT not found" >&2
    exit 1
fi

chmod +x "$LOOP_SCRIPT"

_pass=0
_fail=0

_ok()  { echo "  PASS: $*"; _pass=$((_pass + 1)); }
_bad() { echo "  FAIL: $*" >&2; _fail=$((_fail + 1)); }

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Build a synthetic FEEDBACK proposal inbox line
_make_proposal() {
    local corr_id="$1" subject="$2" rationale="$3" session="${4:-foreign-session}"
    printf '{"event":"FEEDBACK","kind":"proposal","corr_id":"%s","subject":"%s","rationale":"%s","session":"%s","ts":"%s"}\n' \
        "$corr_id" "$subject" "$rationale" "$session" "$(_now_iso)"
}

# Build a regression_attributed ambient event with a given suspect_commits count
_make_regr_event() {
    local count="$1"
    printf '{"ts":"%s","kind":"regression_attributed","suspect_commits":%s,"checks_attributed":"test-foo","green_sha":"abc123"}\n' \
        "$(_now_iso)" "$count"
}

# ── Test 1: bash -n syntax check ──────────────────────────────────────────────
echo "Test 1: bash -n syntax check..."
if bash -n "$LOOP_SCRIPT" 2>/dev/null; then
    _ok "bash -n passes (no syntax errors)"
else
    _bad "bash -n failed — syntax error in ci-audit-loop.sh"
fi

# ── Test 2: feature flag off → noop ──────────────────────────────────────────
echo "Test 2: CHUMP_FLEET_WIRE_V1=0 → tick emits no phase1.5 section..."
_dir2="$(mktemp -d)"
_amb2="$_dir2/ambient.jsonl"
touch "$_amb2"
mkdir -p "$_dir2/inbox"
_out2="$(CHUMP_AMBIENT_LOG="$_amb2" CHUMP_SESSION_ID="test-ci-audit-reactor-flagoff" \
    CHUMP_LOCK_DIR="$_dir2" CHUMP_FLEET_WIRE_V1=0 \
    "$LOOP_SCRIPT" tick 2>&1 || true)"
if ! echo "$_out2" | grep -q "Phase 1.5"; then
    _ok "CHUMP_FLEET_WIRE_V1=0: tick skips Phase 1.5 section"
else
    _bad "CHUMP_FLEET_WIRE_V1=0: tick should not print Phase 1.5 section"
fi
if ! grep -q '"kind":"ci_audit_reactor_voted"' "$_amb2" 2>/dev/null; then
    _ok "CHUMP_FLEET_WIRE_V1=0: no ci_audit_reactor_voted emitted"
else
    _bad "CHUMP_FLEET_WIRE_V1=0: ci_audit_reactor_voted should not be emitted"
fi
rm -rf "$_dir2"

# ── Test 3 (Fixture A): high-confidence regression → vote +1 ─────────────────
echo "Test 3 (Fixture A): regression_attributed proposal, suspect_commits=5 → vote +1..."
_dir3="$(mktemp -d)"
_amb3="$_dir3/ambient.jsonl"
mkdir -p "$_dir3/inbox"
# Inject regression_attributed event into ambient (within last 4h)
_make_regr_event 5 >> "$_amb3"
# Inject FEEDBACK proposal into inbox
_make_proposal "corr-test-high-001" "review regression_attributed failure" "blame-bot triggered regression_attributed on merge" "other-session" \
    > "$_dir3/inbox/test-ci-audit-reactor-highconf.jsonl"
_out3="$(CHUMP_AMBIENT_LOG="$_amb3" CHUMP_SESSION_ID="test-ci-audit-reactor-highconf" \
    CHUMP_LOCK_DIR="$_dir3" CHUMP_FLEET_WIRE_V1=1 \
    "$LOOP_SCRIPT" tick 2>&1 || true)"
if echo "$_out3" | grep -q "vote=1"; then
    _ok "Fixture A: high-confidence vote (+1) cast for suspect_commits=5"
else
    _bad "Fixture A: expected vote=1 in output, got: $( echo "$_out3" | grep phase1.5 || echo '(no phase1.5 lines)')"
fi
if grep -q '"kind":"ci_audit_reactor_voted"' "$_amb3" 2>/dev/null; then
    _ok "Fixture A: ci_audit_reactor_voted emitted to ambient"
else
    _bad "Fixture A: ci_audit_reactor_voted not found in ambient"
fi
if grep -q '"vote":1' "$_amb3" 2>/dev/null; then
    _ok "Fixture A: FEEDBACK vote=1 written to ambient"
else
    _bad "Fixture A: FEEDBACK vote=1 not found in ambient"
fi
rm -rf "$_dir3"

# ── Test 4 (Fixture B): low-confidence regression → vote 0 ────────────────────
echo "Test 4 (Fixture B): regression_attributed proposal, suspect_commits=1 → vote 0..."
_dir4="$(mktemp -d)"
_amb4="$_dir4/ambient.jsonl"
mkdir -p "$_dir4/inbox"
_make_regr_event 1 >> "$_amb4"
_make_proposal "corr-test-low-002" "possible regression_attributed event in CI" "low suspect count" "other-session" \
    > "$_dir4/inbox/test-ci-audit-reactor-lowconf.jsonl"
_out4="$(CHUMP_AMBIENT_LOG="$_amb4" CHUMP_SESSION_ID="test-ci-audit-reactor-lowconf" \
    CHUMP_LOCK_DIR="$_dir4" CHUMP_FLEET_WIRE_V1=1 \
    "$LOOP_SCRIPT" tick 2>&1 || true)"
if echo "$_out4" | grep -q "vote=0"; then
    _ok "Fixture B: low-confidence vote (0) cast for suspect_commits=1"
else
    _bad "Fixture B: expected vote=0 in output, got: $(echo "$_out4" | grep phase1.5 || echo '(no phase1.5 lines)')"
fi
if grep -q '"vote":0' "$_amb4" 2>/dev/null; then
    _ok "Fixture B: FEEDBACK vote=0 written to ambient"
else
    _bad "Fixture B: FEEDBACK vote=0 not found in ambient"
fi
rm -rf "$_dir4"

# ── Test 5 (Fixture C): non-regression proposal → skip ────────────────────────
echo "Test 5 (Fixture C): non-regression proposal → skip..."
_dir5="$(mktemp -d)"
_amb5="$_dir5/ambient.jsonl"
mkdir -p "$_dir5/inbox"
# No regression_attributed in ambient
_make_proposal "corr-test-noop-003" "refactor the frobnicator" "no regression here" "other-session" \
    > "$_dir5/inbox/test-ci-audit-reactor-noop.jsonl"
_out5="$(CHUMP_AMBIENT_LOG="$_amb5" CHUMP_SESSION_ID="test-ci-audit-reactor-noop" \
    CHUMP_LOCK_DIR="$_dir5" CHUMP_FLEET_WIRE_V1=1 \
    "$LOOP_SCRIPT" tick 2>&1 || true)"
if ! grep -q '"kind":"ci_audit_reactor_voted"' "$_amb5" 2>/dev/null; then
    _ok "Fixture C: non-regression proposal skipped (no vote emitted)"
else
    _bad "Fixture C: ci_audit_reactor_voted should NOT be emitted for non-regression proposal"
fi
rm -rf "$_dir5"

# ── Test 6: anti-loop — kind=vote proposal skipped ───────────────────────────
echo "Test 6: anti-loop — kind=vote inbox message → skip..."
_dir6="$(mktemp -d)"
_amb6="$_dir6/ambient.jsonl"
mkdir -p "$_dir6/inbox"
_make_regr_event 5 >> "$_amb6"
# Vote-kind message in inbox — should be skipped
printf '{"event":"FEEDBACK","kind":"vote","corr_id":"corr-vote-skip","subject":"regression_attributed thing","rationale":"regression_attributed ref","session":"other","ts":"%s"}\n' \
    "$(_now_iso)" > "$_dir6/inbox/test-ci-audit-reactor-antiloop.jsonl"
CHUMP_AMBIENT_LOG="$_amb6" CHUMP_SESSION_ID="test-ci-audit-reactor-antiloop" \
    CHUMP_LOCK_DIR="$_dir6" CHUMP_FLEET_WIRE_V1=1 \
    "$LOOP_SCRIPT" tick >/dev/null 2>&1 || true
if ! grep -q '"corr_id":"corr-vote-skip"' "$_amb6" 2>/dev/null \
   || ! grep -q '"kind":"ci_audit_reactor_voted"' "$_amb6" 2>/dev/null; then
    _ok "anti-loop: kind=vote proposal not voted on"
else
    # Check specifically for reactor_voted, not just any vote
    if ! grep -q '"kind":"ci_audit_reactor_voted".*"corr_id":"corr-vote-skip"' "$_amb6" 2>/dev/null \
       && ! grep -q '"corr_id":"corr-vote-skip".*"kind":"ci_audit_reactor_voted"' "$_amb6" 2>/dev/null; then
        _ok "anti-loop: kind=vote proposal not voted on (reactor_voted not emitted for it)"
    else
        _bad "anti-loop: should skip kind=vote proposals"
    fi
fi
rm -rf "$_dir6"

# ── Test 7: anti-loop — own-session proposal skipped ────────────────────────
echo "Test 7: anti-loop — own-session proposal → skip..."
_dir7="$(mktemp -d)"
_amb7="$_dir7/ambient.jsonl"
mkdir -p "$_dir7/inbox"
_make_regr_event 5 >> "$_amb7"
_make_proposal "corr-own-session-007" "regression_attributed issue" "own session regression_attributed" "test-ci-audit-reactor-ownsess" \
    > "$_dir7/inbox/test-ci-audit-reactor-ownsess.jsonl"
CHUMP_AMBIENT_LOG="$_amb7" CHUMP_SESSION_ID="test-ci-audit-reactor-ownsess" \
    CHUMP_LOCK_DIR="$_dir7" CHUMP_FLEET_WIRE_V1=1 \
    "$LOOP_SCRIPT" tick >/dev/null 2>&1 || true
if ! grep -q '"kind":"ci_audit_reactor_voted"' "$_amb7" 2>/dev/null; then
    _ok "anti-loop: own-session proposal skipped"
else
    _bad "anti-loop: should skip own-session proposals"
fi
rm -rf "$_dir7"

# ── Test 8: anti-loop — consensus_result-fired corr_id → skip ───────────────
echo "Test 8: anti-loop — consensus_result already fired → skip..."
_dir8="$(mktemp -d)"
_amb8="$_dir8/ambient.jsonl"
mkdir -p "$_dir8/inbox"
_make_regr_event 5 >> "$_amb8"
# Pre-populate ambient with a consensus_result for this corr_id
printf '{"ts":"%s","kind":"consensus_result","corr_id":"corr-consensus-done","verdict":"PASS"}\n' \
    "$(_now_iso)" >> "$_amb8"
_make_proposal "corr-consensus-done" "regression_attributed fix proposed" "regression_attributed check" "other-session" \
    > "$_dir8/inbox/test-ci-audit-reactor-consensus.jsonl"
CHUMP_AMBIENT_LOG="$_amb8" CHUMP_SESSION_ID="test-ci-audit-reactor-consensus" \
    CHUMP_LOCK_DIR="$_dir8" CHUMP_FLEET_WIRE_V1=1 \
    "$LOOP_SCRIPT" tick >/dev/null 2>&1 || true
_voted_count="$(grep -c '"kind":"ci_audit_reactor_voted"' "$_amb8" 2>/dev/null | tr -d '[:space:]' || echo 0)"
if (( _voted_count == 0 )); then
    _ok "anti-loop: consensus_result-fired corr_id skipped"
else
    _bad "anti-loop: should skip consensus_result-fired corr_ids (found ${_voted_count} reactor_voted events)"
fi
rm -rf "$_dir8"

# ── Test 9: cooldown — second call within 30min → skip ──────────────────────
echo "Test 9: per-corr_id 30min cooldown..."
_dir9="$(mktemp -d)"
_amb9="$_dir9/ambient.jsonl"
mkdir -p "$_dir9/inbox"
mkdir -p "$_dir9/ci-audit-vote-cooldown"
_make_regr_event 5 >> "$_amb9"
_make_proposal "corr-cooldown-009" "regression_attributed crash" "regression_attributed in recent deploy" "other-session" \
    > "$_dir9/inbox/test-ci-audit-reactor-cooldown.jsonl"

# First call — should vote
CHUMP_AMBIENT_LOG="$_amb9" CHUMP_SESSION_ID="test-ci-audit-reactor-cooldown" \
    CHUMP_LOCK_DIR="$_dir9" CHUMP_FLEET_WIRE_V1=1 \
    "$LOOP_SCRIPT" tick >/dev/null 2>&1 || true
_first_vote_count="$(grep -c '"kind":"ci_audit_reactor_voted"' "$_amb9" 2>/dev/null | tr -d '[:space:]' || echo 0)"

# Second call — cooldown file now exists with fresh mtime → should skip
CHUMP_AMBIENT_LOG="$_amb9" CHUMP_SESSION_ID="test-ci-audit-reactor-cooldown" \
    CHUMP_LOCK_DIR="$_dir9" CHUMP_FLEET_WIRE_V1=1 \
    "$LOOP_SCRIPT" tick >/dev/null 2>&1 || true
_second_vote_count="$(grep -c '"kind":"ci_audit_reactor_voted"' "$_amb9" 2>/dev/null | tr -d '[:space:]' || echo 0)"

if (( _first_vote_count == 1 )); then
    _ok "cooldown: first call voted (count=${_first_vote_count})"
else
    _bad "cooldown: first call should have voted once (got ${_first_vote_count})"
fi
if (( _second_vote_count == _first_vote_count )); then
    _ok "cooldown: second call within 30min skipped (count unchanged at ${_second_vote_count})"
else
    _bad "cooldown: second call should be suppressed by cooldown (first=${_first_vote_count}, second=${_second_vote_count})"
fi
rm -rf "$_dir9"

# ── Test 10: scanner-anchor present ──────────────────────────────────────────
echo "Test 10: scanner-anchor for ci_audit_reactor_voted present..."
if grep -q '# scanner-anchor: "kind":"ci_audit_reactor_voted"' "$LOOP_SCRIPT"; then
    _ok "ci_audit_reactor_voted has scanner-anchor comment"
else
    _bad "ci_audit_reactor_voted missing scanner-anchor comment"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: ${_pass} passed, ${_fail} failed"
if (( _fail > 0 )); then
    exit 1
fi
echo "All ci-audit-reactor tests passed"
