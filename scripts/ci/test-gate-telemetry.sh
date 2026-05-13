#!/usr/bin/env bash
# test-gate-telemetry.sh — CREDIBLE-048
#
# Verifies the gate-emit library and gate-fire-rate script work correctly.
# Network-free; self-contained.
#
# Tests:
#   1. gate_emit_start emits gate_check_start to ambient.jsonl
#   2. gate_emit_result emits gate_check_result with correct outcome fields
#   3. gate-fire-rate.sh reads events and produces correct fire-rate stats
#   4. CHUMP_GATE_TELEMETRY=0 suppresses all emission
#   5. GitHub Actions notice annotation emitted when GITHUB_ACTIONS=true
#   6. gate-fire-rate.sh --json produces valid JSON

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_EMIT_LIB="$SCRIPT_DIR/lib/gate-emit.sh"
FIRE_RATE_SCRIPT="$REPO_ROOT/scripts/dispatch/gate-fire-rate.sh"

[[ -f "$GATE_EMIT_LIB" ]] || { echo "FATAL: gate-emit.sh not found at $GATE_EMIT_LIB"; exit 2; }
[[ -x "$FIRE_RATE_SCRIPT" ]] || { echo "FATAL: gate-fire-rate.sh not found at $FIRE_RATE_SCRIPT"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export CHUMP_METRICS_DIR="$TMP/metrics"
mkdir -p "$TMP/metrics"
touch "$CHUMP_AMBIENT_LOG"

# ── Test 1: gate_emit_start emits gate_check_start ───────────────────────────
echo "Test 1: gate_emit_start emits gate_check_start"
(
    source "$GATE_EMIT_LIB"
    gate_emit_start "TEST-GATE-001" "--dry-run"
)
if grep -q '"kind":"gate_check_start"' "$CHUMP_AMBIENT_LOG" && \
   grep -q '"gate":"TEST-GATE-001"' "$CHUMP_AMBIENT_LOG"; then
    ok "gate_check_start emitted with gate name"
else
    fail "gate_check_start not emitted (ambient: $(cat "$CHUMP_AMBIENT_LOG"))"
fi

# ── Test 2: gate_emit_result emits gate_check_result ────────────────────────
echo "Test 2: gate_emit_result emits gate_check_result"
(
    source "$GATE_EMIT_LIB"
    gate_emit_result "TEST-GATE-001" "fail" "test-rule" "some evidence"
)
if grep -q '"kind":"gate_check_result"' "$CHUMP_AMBIENT_LOG" && \
   grep -q '"outcome":"fail"' "$CHUMP_AMBIENT_LOG" && \
   grep -q '"rule_fired":"test-rule"' "$CHUMP_AMBIENT_LOG"; then
    ok "gate_check_result emitted with outcome/rule_fired"
else
    fail "gate_check_result not emitted correctly (ambient: $(cat "$CHUMP_AMBIENT_LOG"))"
fi

# ── Test 3: gate-fire-rate.sh reads events correctly ────────────────────────
echo "Test 3: gate-fire-rate.sh computes fire rate"
# Add a pass result for a second gate
(
    source "$GATE_EMIT_LIB"
    gate_emit_start "TEST-GATE-002" ""
    gate_emit_result "TEST-GATE-002" "pass" "" ""
)
out="$(CHUMP_AMBIENT_LOG="$CHUMP_AMBIENT_LOG" CHUMP_METRICS_DIR="$TMP/metrics" \
    bash "$FIRE_RATE_SCRIPT" 2>&1)"
if echo "$out" | grep -q 'TEST-GATE-001' && echo "$out" | grep -q 'TEST-GATE-002'; then
    ok "gate-fire-rate.sh shows both gates"
else
    fail "gate-fire-rate.sh output missing gates (output: $out)"
fi
if echo "$out" | grep 'TEST-GATE-001' | grep -q '100.0%\|100%'; then
    ok "TEST-GATE-001 fire rate 100% (1 fire / 1 check)"
else
    fail "TEST-GATE-001 fire rate wrong (output: $out)"
fi

# Metrics file created
if [[ -f "$TMP/metrics/gate-fire-rate.jsonl" ]]; then
    ok "gate-fire-rate.jsonl created in metrics dir"
else
    fail "gate-fire-rate.jsonl not created"
fi

# ── Test 4: CHUMP_GATE_TELEMETRY=0 suppresses emission ──────────────────────
echo "Test 4: CHUMP_GATE_TELEMETRY=0 suppresses events"
> "$CHUMP_AMBIENT_LOG"  # clear
(
    export CHUMP_GATE_TELEMETRY=0
    source "$GATE_EMIT_LIB"
    gate_emit_start "TEST-GATE-003" ""
    gate_emit_result "TEST-GATE-003" "fail" "" ""
)
if [[ ! -s "$CHUMP_AMBIENT_LOG" ]]; then
    ok "CHUMP_GATE_TELEMETRY=0 suppressed emission (ambient empty)"
else
    fail "CHUMP_GATE_TELEMETRY=0 did not suppress (ambient: $(cat "$CHUMP_AMBIENT_LOG"))"
fi

# ── Test 5: GitHub Actions notice annotation ─────────────────────────────────
echo "Test 5: ::notice:: annotation emitted when GITHUB_ACTIONS=true"
notice_out="$(
    GITHUB_ACTIONS=true source "$GATE_EMIT_LIB" 2>/dev/null || true
    GITHUB_ACTIONS=true CHUMP_AMBIENT_LOG="$CHUMP_AMBIENT_LOG" \
        bash -c "source \"$GATE_EMIT_LIB\"; gate_emit_result 'TEST-GATE-004' 'fail' 'my-rule' ''" 2>&1
)"
if echo "$notice_out" | grep -q '::notice'; then
    ok "::notice:: annotation emitted in GITHUB_ACTIONS context"
else
    fail "::notice:: annotation NOT emitted (output: $notice_out)"
fi

# ── Test 6: gate-fire-rate.sh --json produces valid JSON ─────────────────────
echo "Test 6: gate-fire-rate.sh --json produces valid JSON"
> "$CHUMP_AMBIENT_LOG"
(
    source "$GATE_EMIT_LIB"
    gate_emit_start "TEST-GATE-005" ""
    gate_emit_result "TEST-GATE-005" "pass" "" ""
)
json_out="$(CHUMP_AMBIENT_LOG="$CHUMP_AMBIENT_LOG" CHUMP_METRICS_DIR="$TMP/metrics" \
    bash "$FIRE_RATE_SCRIPT" --json 2>&1)"
if echo "$json_out" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    ok "gate-fire-rate.sh --json produces valid JSON"
else
    fail "gate-fire-rate.sh --json output is not valid JSON (output: $json_out)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
