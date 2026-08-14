#!/usr/bin/env bash
# scripts/ci/test-operator-recall-autonomy-halt.sh — RESILIENT-321
#
# Verifies the AUTONOMY_HALT condition in scripts/dispatch/operator-recall.sh:
# a fleet_stopped_kill_switch halt sustained for >= CHUMP_AUTONOMY_HALT_MIN_SECS
# with AUTONOMY_LEVEL still 0 must page the operator via --check-only exit 1 +
# kind=operator_recall,condition=AUTONOMY_HALT. Precedent: a refresh/provision
# reset AUTONOMY_LEVEL to 0 on 2026-08-14 and the fleet sat silently halted 6h
# — worker.sh/bot-merge.sh emit fleet_stopped_kill_switch every cycle, but
# nothing ever consumed a *sustained* streak of them to escalate.
#
#   1. Fresh halt (age < threshold)     → no AUTONOMY_HALT recall
#   2. Sustained halt (age >= threshold) + AUTONOMY_LEVEL=0 → AUTONOMY_HALT recall
#   3. Sustained halt events present BUT AUTONOMY_LEVEL now >0 (recovered) → no recall
#
# All tests use a temporary HOME + ambient log so they never touch the real
# ~/.chump/AUTONOMY_LEVEL or .chump-locks/ambient.jsonl.
#
# Exit 0 = all pass. Exit 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECALL="$REPO_ROOT/scripts/dispatch/operator-recall.sh"

PASS=0
FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" >&2; FAIL=$((FAIL+1)); }

FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT
mkdir -p "$FAKE_HOME/.chump"
AL_FILE="$FAKE_HOME/.chump/AUTONOMY_LEVEL"
FAKE_AMBIENT="$FAKE_HOME/ambient.jsonl"

# Keep every OTHER operator-recall condition from tripping and confusing the
# result — none of their trigger events exist in FAKE_AMBIENT, but pin the
# thresholds tight anyway so this test is robust to future default changes.
export CHUMP_AUTONOMY_HALT_MIN_SECS=1800
export CHUMP_AUTONOMY_HALT_WINDOW_SECS=86400
export CHUMP_AMBIENT_LOG="$FAKE_AMBIENT"
export REPO_ROOT

_run() {
    HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" REPO_ROOT="$REPO_ROOT" \
        bash "$RECALL" --check-only
}

_emit_halt() {
    # $1 = age in seconds (how long ago the event happened)
    local age="$1"
    local epoch; epoch=$(( $(date +%s) - age ))
    local ts; ts="$(python3 -c "
import sys
from datetime import datetime, timezone
print(datetime.fromtimestamp(int(sys.argv[1]), tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$epoch")"
    printf '{"ts":"%s","kind":"fleet_stopped_kill_switch","source":"worker","agent_id":"test","autonomy_level":0,"note":"RESILIENT-073"}\n' "$ts" >> "$FAKE_AMBIENT"
}

# ── Test 1: fresh halt (age < threshold) → no AUTONOMY_HALT recall ──────────
echo "0" > "$AL_FILE"
> "$FAKE_AMBIENT"
_emit_halt 60   # 1 minute ago, well under the 1800s threshold
_out="$(_run 2>&1)"; _rc=$?
if echo "$_out" | grep -q "AUTONOMY_HALT"; then
    fail "Test 1: fresh halt (60s) incorrectly triggered AUTONOMY_HALT: $_out"
else
    ok "Test 1: fresh halt (60s) did not trigger AUTONOMY_HALT (rc=$_rc)"
fi

# ── Test 2: sustained halt (age >= threshold) + AUTONOMY_LEVEL=0 → recall ───
echo "0" > "$AL_FILE"
> "$FAKE_AMBIENT"
_emit_halt 7200   # 2 hours ago, well over the 1800s threshold
_out="$(_run 2>&1)"; _rc=$?
if echo "$_out" | grep -q "HALT condition=AUTONOMY_HALT"; then
    ok "Test 2: sustained halt (2h) triggered AUTONOMY_HALT"
else
    fail "Test 2: sustained halt (2h) did NOT trigger AUTONOMY_HALT: $_out"
fi
if [[ "$_rc" -eq 1 ]]; then
    ok "Test 2: --check-only exited 1 on sustained halt"
else
    fail "Test 2: --check-only expected exit 1, got $_rc"
fi

# ── Test 3: sustained halt events present but AUTONOMY_LEVEL now >0 ─────────
# (operator already resumed the fleet — must not page on stale history)
echo "5" > "$AL_FILE"
> "$FAKE_AMBIENT"
_emit_halt 7200
_out="$(_run 2>&1)"; _rc=$?
if echo "$_out" | grep -q "AUTONOMY_HALT"; then
    fail "Test 3: recovered fleet (AUTONOMY_LEVEL=5) incorrectly triggered AUTONOMY_HALT: $_out"
else
    ok "Test 3: recovered fleet (AUTONOMY_LEVEL=5) did not trigger AUTONOMY_HALT"
fi

# ── Test 4: non-check-only mode emits kind=operator_recall,condition=AUTONOMY_HALT ──
echo "0" > "$AL_FILE"
> "$FAKE_AMBIENT"
_emit_halt 7200
HOME="$FAKE_HOME" CHUMP_AMBIENT_LOG="$FAKE_AMBIENT" REPO_ROOT="$REPO_ROOT" \
    bash "$RECALL" >/dev/null 2>&1 || true
if grep -q '"kind":"operator_recall"' "$FAKE_AMBIENT" && grep -q '"condition":"AUTONOMY_HALT"' "$FAKE_AMBIENT"; then
    ok "Test 4: non-check-only run emitted operator_recall/AUTONOMY_HALT to ambient"
else
    fail "Test 4: no operator_recall/AUTONOMY_HALT event found in ambient: $(cat "$FAKE_AMBIENT")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
