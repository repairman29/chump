#!/usr/bin/env bash
# test-effective-441-unverified-ship-escalation.sh — EFFECTIVE-441
#
# An unverified_ship gap (claimed + worked, rc=0, but no merging PR) used to
# be released straight back to `open` and re-picked next cycle forever —
# RESILIENT-354 was re-picked by the same worker at cycle 130 AND 135 with no
# ship in between. This test proves:
#
#   1. the persistent per-gap counter in _unverified_ship_escalation.py
#      increments monotonically across independent calls (i.e. survives
#      across "workers"/"cycles", unlike the per-worker cooldown file)
#   2. decide_action() stays "none" below the escalate threshold, flips to
#      "escalate" at N, and to "park" at M — so no single gap can loop past
#      M consecutive unverified_ship attempts without being taken out of the
#      open pool
#   3. `clear` resets the counter (a verified ship shouldn't carry stale
#      escalation history)
#   4. worker.sh is actually wired to call the helper and act on escalate/park
#      (bump required_model, flip status away from open) — without this
#      wiring the counter would be inert and the loop would recur
#
# Run: ./scripts/ci/test-effective-441-unverified-ship-escalation.sh

set -uo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/dispatch/_unverified_ship_escalation.py"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"

echo "=== EFFECTIVE-441 unverified_ship escalation tests ==="
echo

if [[ ! -f "$HELPER" ]]; then
    fail "helper script missing: $HELPER"
    echo
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
fi

_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT

# ── Test 1: counter increments monotonically across independent invocations ──
echo "--- Test 1: counter persists + increments across calls ---"
_r1="$(python3 "$HELPER" record "$_tmpdir" GAP-A --escalate-n 3 --park-m 6)"
_r2="$(python3 "$HELPER" record "$_tmpdir" GAP-A --escalate-n 3 --park-m 6)"
_c1="$(awk '{print $1}' <<<"$_r1")"
_c2="$(awk '{print $1}' <<<"$_r2")"
if [[ "$_c1" == "1" && "$_c2" == "2" ]]; then
    ok "Test 1: counter went 1 then 2 across separate invocations"
else
    fail "Test 1: expected counts 1,2 got '$_c1','$_c2'"
fi

# ── Test 2: below threshold => none ──────────────────────────────────────────
echo "--- Test 2: action=none below escalate threshold ---"
_a2="$(awk '{print $2}' <<<"$_r2")"
if [[ "$_a2" == "none" ]]; then
    ok "Test 2: action=none at count=2 (escalate-n=3)"
else
    fail "Test 2: expected action=none at count=2, got '$_a2'"
fi

# ── Test 3: at N => escalate ─────────────────────────────────────────────────
echo "--- Test 3: action=escalate at N ---"
_r3="$(python3 "$HELPER" record "$_tmpdir" GAP-A --escalate-n 3 --park-m 6)"
_c3="$(awk '{print $1}' <<<"$_r3")"
_a3="$(awk '{print $2}' <<<"$_r3")"
if [[ "$_c3" == "3" && "$_a3" == "escalate" ]]; then
    ok "Test 3: action=escalate at count=3"
else
    fail "Test 3: expected count=3 action=escalate, got count='$_c3' action='$_a3'"
fi

# ── Test 4: no single gap re-attempted more than M times without parking ────
echo "--- Test 4: action=park at M, and stays park beyond M ---"
python3 "$HELPER" record "$_tmpdir" GAP-A --escalate-n 3 --park-m 6 >/dev/null  # 4
python3 "$HELPER" record "$_tmpdir" GAP-A --escalate-n 3 --park-m 6 >/dev/null  # 5
_r6="$(python3 "$HELPER" record "$_tmpdir" GAP-A --escalate-n 3 --park-m 6)"    # 6
_c6="$(awk '{print $1}' <<<"$_r6")"
_a6="$(awk '{print $2}' <<<"$_r6")"
_r7="$(python3 "$HELPER" record "$_tmpdir" GAP-A --escalate-n 3 --park-m 6)"    # 7 (would only
_a7="$(awk '{print $2}' <<<"$_r7")"                                             # happen pre-park)
if [[ "$_c6" == "6" && "$_a6" == "park" && "$_a7" == "park" ]]; then
    ok "Test 4: action=park at count=6 and remains park at count=7"
else
    fail "Test 4: expected park at 6 and 7, got a6='$_a6' a7='$_a7' (count=$_c6)"
fi

# ── Test 5: a different gap has its own independent counter ─────────────────
echo "--- Test 5: counters are per-gap, not global ---"
_rb="$(python3 "$HELPER" record "$_tmpdir" GAP-B --escalate-n 3 --park-m 6)"
_cb="$(awk '{print $1}' <<<"$_rb")"
if [[ "$_cb" == "1" ]]; then
    ok "Test 5: GAP-B starts at count=1 independent of GAP-A's history"
else
    fail "Test 5: expected GAP-B count=1, got '$_cb'"
fi

# ── Test 6: clear resets the counter ─────────────────────────────────────────
echo "--- Test 6: clear resets the counter (verified ship forgets history) ---"
python3 "$HELPER" clear "$_tmpdir" GAP-A
_after_clear="$(python3 "$HELPER" show "$_tmpdir" GAP-A)"
if [[ "$_after_clear" == "0" ]]; then
    ok "Test 6: GAP-A counter reads 0 after clear"
else
    fail "Test 6: expected 0 after clear, got '$_after_clear'"
fi

# ── Test 7: worker.sh actually calls the helper on unverified_ship ──────────
echo "--- Test 7: worker.sh wires the helper into the unverified_ship path ---"
if grep -q '_unverified_ship_escalation.py' "$WORKER" && \
   grep -q 'CHUMP_UNVERIFIED_SHIP_ESCALATE_N' "$WORKER" && \
   grep -q 'CHUMP_UNVERIFIED_SHIP_PARK_M' "$WORKER"; then
    ok "Test 7: worker.sh calls the escalation helper with tunable thresholds"
else
    fail "Test 7: worker.sh missing wiring to _unverified_ship_escalation.py"
fi

# ── Test 8: worker.sh acts on escalate (model bump) ──────────────────────────
echo "--- Test 8: worker.sh bumps required_model on escalate ---"
if grep -q 'gap set "\$GAP_ID" --required-model opus' "$WORKER"; then
    ok "Test 8: worker.sh escalates required_model to opus"
else
    fail "Test 8: worker.sh does not bump required_model on escalate"
fi

# ── Test 9: worker.sh acts on park (status flip out of open pool) ───────────
echo "--- Test 9: worker.sh parks the gap out of the open pool at M ---"
if grep -q 'gap set "\$GAP_ID" --status needs_decompose' "$WORKER"; then
    ok "Test 9: worker.sh flips status to needs_decompose on park"
else
    fail "Test 9: worker.sh does not park the gap on hitting M"
fi

# ── Test 10: a verified ship clears the counter ──────────────────────────────
echo "--- Test 10: worker.sh clears the counter on verified ship ---"
if awk '/_cycle_kind="shipped"/,/else/' "$WORKER" | grep -q '_unverified_ship_escalation.py'; then
    ok "Test 10: worker.sh clears the unverified_ship counter on shipped"
else
    fail "Test 10: worker.sh does not clear the counter on a verified ship"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
