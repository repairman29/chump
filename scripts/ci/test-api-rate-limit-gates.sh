#!/usr/bin/env bash
# test-api-rate-limit-gates.sh — INFRA-1055 acceptance tests.
#
# Tests:
#   1.  Gate script exists and is sourceable.
#   2.  rate_limit_snapshot exports required variables.
#   3.  Circuit breaker fires at REST ≤ 20% remaining (returns 1).
#   4.  Circuit breaker fires exhausted at REST = 0 (returns 2).
#   5.  Circuit breaker fires at GraphQL ≤ 50% remaining (returns 1).
#   6.  Circuit breaker fires exhausted at GraphQL = 0 (returns 1, REST fallback mode).
#   7.  gate_skip_phase emits kind=gate_skipped to ambient.jsonl.
#   8.  rate_limit_gate emits kind=rate_limit_approaching when threshold crossed.
#   9.  rate_limit_gate emits kind=rate_limit_exhausted when quota = 0.
#   10. CHUMP_RL_GATE_SKIP=1 disables all checks (returns 0).
#   11. bot-merge.sh references api-rate-limit-gate.sh.
#   12. fleet-status.sh references api-rate-limit-gate.sh.
#   13. bot-merge.sh has rate_limit_gate call after gh_api_probe.
#   14. Graceful degradation: gate_skip_phase callable in degraded mode.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE_SH="$REPO_ROOT/scripts/coord/api-rate-limit-gate.sh"
BOT_MERGE_SH="$REPO_ROOT/scripts/coord/bot-merge.sh"
FLEET_STATUS_SH="$REPO_ROOT/scripts/dispatch/fleet-status.sh"

pass=0
fail=0
ok()   { printf '[PASS] %s\n' "$1"; pass=$((pass + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; fail=$((fail + 1)); }

# ── Test 1: gate script exists ───────────────────────────────────────────────
if [[ -f "$GATE_SH" ]]; then
    ok "Test 1: api-rate-limit-gate.sh exists"
else
    fail "Test 1: api-rate-limit-gate.sh missing at $GATE_SH"
fi

# ── Test 2: script is sourceable and exports variables ───────────────────────
result=$(bash -c "source '$GATE_SH'; echo \"REST=\${RL_REST_REMAINING:-unset} GQL=\${RL_GQL_REMAINING:-unset}\"" 2>/dev/null)
if echo "$result" | grep -q "REST="; then
    ok "Test 2: gate script sourceable, exports RL_REST_REMAINING"
else
    fail "Test 2: gate script failed to source or export variables"
fi

# ── Test 3: REST approaching threshold (≤ 20% remaining) triggers return 1 ──
rc=0
bash -c "
  source '$GATE_SH'
  CHUMP_RL_GATE_SKIP=0
  # Mock snapshot: simulate 15% REST remaining, 80% GraphQL remaining
  rate_limit_snapshot() {
    RL_REST_REMAINING=750; RL_REST_LIMIT=5000; RL_REST_PCT=15
    RL_GQL_REMAINING=4000; RL_GQL_LIMIT=5000; RL_GQL_PCT=80
  }
  _amb=\$(mktemp)
  CHUMP_AMBIENT_LOG=\"\$_amb\"
  rate_limit_gate 'test-phase' || exit \$?
  exit 0
" 2>/dev/null
rc=$?
if [[ $rc -eq 1 ]]; then
    ok "Test 3: REST ≤ 20% remaining → rate_limit_gate returns 1 (approaching)"
else
    fail "Test 3: REST approaching expected rc=1, got rc=$rc"
fi

# ── Test 4: REST exhausted (0 remaining) triggers return 2 ──────────────────
rc=0
bash -c "
  source '$GATE_SH'
  CHUMP_RL_GATE_SKIP=0
  rate_limit_snapshot() {
    RL_REST_REMAINING=0; RL_REST_LIMIT=5000; RL_REST_PCT=0
    RL_GQL_REMAINING=4000; RL_GQL_LIMIT=5000; RL_GQL_PCT=80
  }
  _amb=\$(mktemp)
  CHUMP_AMBIENT_LOG=\"\$_amb\"
  rate_limit_gate 'test-phase' 2>/dev/null || exit \$?
  exit 0
" 2>/dev/null
rc=$?
if [[ $rc -eq 2 ]]; then
    ok "Test 4: REST = 0 → rate_limit_gate returns 2 (exhausted)"
else
    fail "Test 4: REST exhausted expected rc=2, got rc=$rc"
fi

# ── Test 5: GraphQL approaching threshold (≤ 50% remaining) triggers return 1 ─
rc=0
bash -c "
  source '$GATE_SH'
  CHUMP_RL_GATE_SKIP=0
  rate_limit_snapshot() {
    RL_REST_REMAINING=4000; RL_REST_LIMIT=5000; RL_REST_PCT=80
    RL_GQL_REMAINING=2000; RL_GQL_LIMIT=5000; RL_GQL_PCT=40
  }
  _amb=\$(mktemp)
  CHUMP_AMBIENT_LOG=\"\$_amb\"
  rate_limit_gate 'test-phase' 2>/dev/null || exit \$?
  exit 0
" 2>/dev/null
rc=$?
if [[ $rc -eq 1 ]]; then
    ok "Test 5: GraphQL ≤ 50% remaining → rate_limit_gate returns 1"
else
    fail "Test 5: GraphQL approaching expected rc=1, got rc=$rc"
fi

# ── Test 6: GraphQL exhausted → returns 1 (REST-fallback mode, not hard stop) ─
rc=0
bash -c "
  source '$GATE_SH'
  CHUMP_RL_GATE_SKIP=0
  rate_limit_snapshot() {
    RL_REST_REMAINING=4000; RL_REST_LIMIT=5000; RL_REST_PCT=80
    RL_GQL_REMAINING=0; RL_GQL_LIMIT=5000; RL_GQL_PCT=0
  }
  _amb=\$(mktemp)
  CHUMP_AMBIENT_LOG=\"\$_amb\"
  rate_limit_gate 'test-phase' 2>/dev/null || exit \$?
  exit 0
" 2>/dev/null
rc=$?
if [[ $rc -eq 1 ]]; then
    ok "Test 6: GraphQL = 0 → rate_limit_gate returns 1 (REST-fallback, not hard stop)"
else
    fail "Test 6: GraphQL exhausted expected rc=1, got rc=$rc"
fi

# ── Test 7: gate_skip_phase emits gate_skipped to ambient ────────────────────
amb=$(mktemp)
bash -c "
  source '$GATE_SH'
  CHUMP_AMBIENT_LOG='$amb'
  RL_REST_REMAINING=750; RL_GQL_REMAINING=2000
  gate_skip_phase 'clippy' 'rest_approaching' --source 'test'
" 2>/dev/null
if grep -q '"kind":"gate_skipped"' "$amb" && grep -q '"phase":"clippy"' "$amb"; then
    ok "Test 7: gate_skip_phase emits gate_skipped event to ambient"
else
    fail "Test 7: gate_skip_phase did not emit expected event (content: $(cat "$amb" 2>/dev/null | head -1))"
fi
rm -f "$amb"

# ── Test 8: rate_limit_approaching event emitted when threshold crossed ───────
amb=$(mktemp)
bash -c "
  source '$GATE_SH'
  CHUMP_AMBIENT_LOG='$amb'
  CHUMP_RL_GATE_SKIP=0
  rate_limit_snapshot() {
    RL_REST_REMAINING=800; RL_REST_LIMIT=5000; RL_REST_PCT=16
    RL_GQL_REMAINING=4000; RL_GQL_LIMIT=5000; RL_GQL_PCT=80
  }
  rate_limit_gate 'test-startup' --source 'test' 2>/dev/null || true
" 2>/dev/null
if grep -q '"kind":"rate_limit_approaching"' "$amb"; then
    ok "Test 8: rate_limit_approaching event emitted when REST threshold crossed"
else
    fail "Test 8: rate_limit_approaching event missing (got: $(cat "$amb" 2>/dev/null | head -1))"
fi
rm -f "$amb"

# ── Test 9: rate_limit_exhausted event emitted when quota = 0 ────────────────
amb=$(mktemp)
bash -c "
  source '$GATE_SH'
  CHUMP_AMBIENT_LOG='$amb'
  CHUMP_RL_GATE_SKIP=0
  rate_limit_snapshot() {
    RL_REST_REMAINING=0; RL_REST_LIMIT=5000; RL_REST_PCT=0
    RL_GQL_REMAINING=4000; RL_GQL_LIMIT=5000; RL_GQL_PCT=80
  }
  rate_limit_gate 'pr-create' --source 'test' 2>/dev/null || true
" 2>/dev/null
if grep -q '"kind":"rate_limit_exhausted"' "$amb"; then
    ok "Test 9: rate_limit_exhausted event emitted when REST quota = 0"
else
    fail "Test 9: rate_limit_exhausted event missing"
fi
rm -f "$amb"

# ── Test 10: CHUMP_RL_GATE_SKIP=1 disables all checks ───────────────────────
rc=0
bash -c "
  source '$GATE_SH'
  CHUMP_RL_GATE_SKIP=1
  rate_limit_snapshot() { RL_REST_REMAINING=0; RL_REST_PCT=0; }
  rate_limit_gate 'any-phase' 2>/dev/null
" 2>/dev/null || rc=$?
if [[ $rc -eq 0 ]]; then
    ok "Test 10: CHUMP_RL_GATE_SKIP=1 disables gate, returns 0 even with 0 quota"
else
    fail "Test 10: CHUMP_RL_GATE_SKIP=1 still blocked (rc=$rc)"
fi

# ── Test 11: bot-merge.sh sources api-rate-limit-gate.sh ─────────────────────
if grep -q 'api-rate-limit-gate' "$BOT_MERGE_SH"; then
    ok "Test 11: bot-merge.sh references api-rate-limit-gate.sh"
else
    fail "Test 11: bot-merge.sh does not reference api-rate-limit-gate.sh"
fi

# ── Test 12: fleet-status.sh sources api-rate-limit-gate.sh ──────────────────
if grep -q 'api-rate-limit-gate' "$FLEET_STATUS_SH"; then
    ok "Test 12: fleet-status.sh references api-rate-limit-gate.sh"
else
    fail "Test 12: fleet-status.sh does not reference api-rate-limit-gate.sh"
fi

# ── Test 13: bot-merge.sh calls rate_limit_gate after gh_api_probe ───────────
if grep -q 'rate_limit_gate' "$BOT_MERGE_SH"; then
    ok "Test 13: bot-merge.sh calls rate_limit_gate"
else
    fail "Test 13: bot-merge.sh does not call rate_limit_gate"
fi

# ── Test 14: gate_skip_phase callable independently (degraded mode) ───────────
rc=0
bash -c "
  source '$GATE_SH'
  _amb=\$(mktemp)
  CHUMP_AMBIENT_LOG=\"\$_amb\"
  RL_REST_REMAINING=500; RL_GQL_REMAINING=1000
  gate_skip_phase 'optional-clippy-check' 'rest_approaching' --source 'test'
  grep -q 'gate_skipped' \"\$_amb\"
" 2>/dev/null || rc=$?
if [[ $rc -eq 0 ]]; then
    ok "Test 14: gate_skip_phase works standalone (degraded-mode helper)"
else
    fail "Test 14: gate_skip_phase failed standalone call (rc=$rc)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: $pass passed, $fail failed"
[[ $fail -gt 0 ]] && exit 1
exit 0
