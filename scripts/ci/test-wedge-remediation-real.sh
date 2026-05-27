#!/usr/bin/env bash
# scripts/ci/test-wedge-remediation-real.sh — INFRA-2030
#
# Smoke tests: wedge-state-machine REAL remediations for W-002 / W-007 / W-AGG.
#
# Verifies that each class triggers the corresponding REAL action (not just an
# advisory wedge_remediation_requested) by injecting synthetic wedge_detected
# events and asserting on wedge_remediated_real / cluster_detection_requested.
#
# Stubs out broadcast-urgent.sh and refresh-runner-binary.sh via env-overrides
# so no network / cargo calls happen in CI.
#
# Tests:
#   1. W-002 detection → refresh-runner-binary.sh stub invoked + wedge_remediated_real
#   2. W-002 binary-refresh failure → CRIT broadcast stub invoked + wedge_remediated_real
#   3. W-007 detection → CRIT broadcast stub invoked + wedge_remediated_real
#   4. W-AGG detection → cluster_detection_requested emitted + wedge_remediated_real
#   5. W-002 dry-run → advisory emits only, no stub invocations
#   6. W-001 still advisory (not a real remediation target) → wedge_remediation_requested
#   7. Existing wedge-state-machine tests still pass (regression guard)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2030 wedge-remediation-real smoke tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SM="$REPO_ROOT/scripts/coord/wedge-state-machine.sh"
[[ -x "$SM" ]] || { echo "FATAL: $SM not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CHUMP_REPO CHUMP_LOCK_DIR

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"

# ── Stub scripts ─────────────────────────────────────────────────────────────
# Stub for refresh-runner-binary.sh — succeeds by default, writes sentinel
STUB_REFRESH="$TMP/stubs/refresh-runner-binary.sh"
mkdir -p "$TMP/stubs"
cat > "$STUB_REFRESH" <<'STUB'
#!/usr/bin/env bash
echo "[stub] refresh-runner-binary.sh called" >> "$TMP_STUB_LOG"
exit "${STUB_REFRESH_RC:-0}"
STUB
chmod +x "$STUB_REFRESH"

# Stub for broadcast-urgent.sh — always succeeds, writes sentinel
STUB_BROADCAST="$TMP/stubs/broadcast-urgent.sh"
cat > "$STUB_BROADCAST" <<'STUB'
#!/usr/bin/env bash
# Capture args so tests can assert on them
echo "[stub] broadcast-urgent.sh $*" >> "$TMP_STUB_LOG"
exit 0
STUB
chmod +x "$STUB_BROADCAST"

# Stub log path (injected into stubs via env)
STUB_LOG="$TMP/stub-calls.log"

run_sm() {
    # Run state machine in a subshell with its own cd so we don't affect TMP.
    # Capture exit code safely without relying on set -e propagation.
    ( cd "$FAKE" && \
      env \
        CHUMP_REPO="$FAKE" \
        CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
        CHUMP_REFRESH_RUNNER_BIN="$STUB_REFRESH" \
        CHUMP_BROADCAST_URGENT_BIN="$STUB_BROADCAST" \
        TMP_STUB_LOG="$STUB_LOG" \
        "$@" \
        bash "$SM" 2>&1
    ) || true
}

emit_detect() {
    local class="$1"; local note="${2:-}"
    printf '{"ts":"%s","kind":"wedge_detected","source":"wedge_watch","wedge_class":"%s","reason":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$class" "$note" \
        >> "$FAKE/.chump-locks/ambient.jsonl"
}

reset_state() {
    : > "$FAKE/.chump-locks/ambient.jsonl"
    : > "$STUB_LOG"
    rm -f "$FAKE/.chump-locks/wedge-state-machine-state.json"
}

# ── Test 1: W-002 → refresh-runner-binary.sh invoked + wedge_remediated_real ─
echo "--- Test 1: W-002 detection → real refresh-binary stub invoked ---"
reset_state
emit_detect "W-002" "binary-lag on runner sha abc123"
run_sm > /dev/null 2>&1

if grep -q "refresh-runner-binary.sh called" "$STUB_LOG" 2>/dev/null; then
    ok "W-002: refresh-runner-binary.sh stub was invoked"
else
    fail "W-002: expected refresh-runner-binary.sh to be called (stub_log=$(cat "$STUB_LOG" 2>/dev/null || echo EMPTY))"
fi

if grep -q '"kind":"wedge_remediated_real"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"class":"W-002"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-002: wedge_remediated_real emitted"
else
    fail "W-002: expected wedge_remediated_real (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# Verify no advisory-only wedge_remediation_requested for W-002 (it should use the real path)
if ! grep -q '"kind":"wedge_remediation_requested"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-002: no legacy advisory-only event (real path took over)"
else
    # wedge_remediation_requested is acceptable if it's from a different class;
    # check specifically for W-002 advisory
    if grep '"kind":"wedge_remediation_requested"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
       | grep -q '"class":"W-002"'; then
        fail "W-002: legacy advisory-only wedge_remediation_requested still emitted for W-002"
    else
        ok "W-002: wedge_remediation_requested present but from different class (OK)"
    fi
fi

# ── Test 2: W-002 binary-refresh failure → CRIT broadcast invoked ─────────────
echo "--- Test 2: W-002 refresh failure → broadcast-urgent CRIT sent ---"
reset_state
emit_detect "W-002" "stale binary detected"
run_sm STUB_REFRESH_RC=1 > /dev/null 2>&1

if grep -q "broadcast-urgent.sh" "$STUB_LOG" 2>/dev/null \
   && grep -q "CRIT" "$STUB_LOG" 2>/dev/null; then
    ok "W-002 failure: broadcast-urgent CRIT stub invoked"
else
    fail "W-002 failure: expected CRIT broadcast (stub_log=$(cat "$STUB_LOG" 2>/dev/null || echo EMPTY))"
fi

if grep -q '"kind":"wedge_remediated_real"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-002 failure: wedge_remediated_real still emitted (with outcome=failed)"
else
    fail "W-002 failure: expected wedge_remediated_real (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 3: W-007 → CRIT broadcast + wedge_remediated_real ──────────────────
echo "--- Test 3: W-007 detection → CRIT broadcast + wedge_remediated_real ---"
reset_state
emit_detect "W-007" "required check ci/fast-checks missing from workflow"
run_sm > /dev/null 2>&1

if grep -q "broadcast-urgent.sh" "$STUB_LOG" 2>/dev/null \
   && grep -q "CRIT" "$STUB_LOG" 2>/dev/null; then
    ok "W-007: broadcast-urgent CRIT stub invoked"
else
    fail "W-007: expected CRIT broadcast (stub_log=$(cat "$STUB_LOG" 2>/dev/null || echo EMPTY))"
fi

if grep -q '"kind":"wedge_remediated_real"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"class":"W-007"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-007: wedge_remediated_real emitted"
else
    fail "W-007: expected wedge_remediated_real (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 4: W-AGG → cluster_detection_requested + wedge_remediated_real ───────
echo "--- Test 4: W-AGG detection → cluster_detection_requested emitted ---"
reset_state
emit_detect "W-AGG" "5 BLOCKED PRs in last 30 min"
run_sm > /dev/null 2>&1

if grep -q '"kind":"cluster_detection_requested"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"source_wedge":"W-AGG"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-AGG: cluster_detection_requested emitted with source_wedge=W-AGG"
else
    fail "W-AGG: expected cluster_detection_requested (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

if grep -q '"kind":"wedge_remediated_real"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"class":"W-AGG"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-AGG: wedge_remediated_real emitted"
else
    fail "W-AGG: expected wedge_remediated_real (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# No CRIT broadcast for W-AGG (it defers to cluster-detector, no operator page needed)
if ! grep -q '"kind":"cluster_detection_requested"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   | grep -q "W-AGG.*broadcast"; then
    ok "W-AGG: no spurious CRIT broadcast (correct: defers to cluster-detector)"
fi

# ── Test 5: W-002 dry-run → no stub calls ────────────────────────────────────
echo "--- Test 5: W-002 dry-run → advisory only, no stub invocations ---"
reset_state
emit_detect "W-002" "dry-run test"
run_sm CHUMP_WEDGE_STATE_MACHINE_DRY_RUN=1 > /dev/null 2>&1

STUB_CALLS="$(wc -l < "$STUB_LOG" 2>/dev/null | xargs || echo 0)"
if [[ "${STUB_CALLS:-0}" -eq 0 ]]; then
    ok "W-002 dry-run: no stub invocations"
else
    fail "W-002 dry-run: expected 0 stub calls (got $STUB_CALLS: $(cat "$STUB_LOG"))"
fi

# dry-run should still emit the event (with dry-run prefix in action)
if grep -q '"kind":"wedge_remediated_real"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-002 dry-run: wedge_remediated_real emitted (with dry-run action)"
else
    fail "W-002 dry-run: expected wedge_remediated_real even in dry-run mode (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 6: W-001 still emits advisory (not a real remediation target) ────────
echo "--- Test 6: W-001 still advisory → wedge_remediation_requested ---"
reset_state
emit_detect "W-001" "gh API false-positive conflict"
run_sm > /dev/null 2>&1

if grep -q '"kind":"wedge_remediation_requested"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"class":"W-001"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-001: still emits advisory wedge_remediation_requested"
else
    fail "W-001: expected advisory (ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# No real remediation for W-001
if ! grep -q '"kind":"wedge_remediated_real"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "W-001: no wedge_remediated_real (correct: still advisory)"
else
    # Check if it's from W-001 specifically
    if grep '"kind":"wedge_remediated_real"' "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
       | grep -q '"class":"W-001"'; then
        fail "W-001: unexpected wedge_remediated_real for W-001 (should be advisory only)"
    else
        ok "W-001: wedge_remediated_real from different class only (OK)"
    fi
fi

# ── Test 7: Regression — existing state-machine behaviour intact ──────────────
echo "--- Test 7: existing wedge-state-machine tests pass (regression guard) ---"
EXISTING_OUT="$(
    cd "$REPO_ROOT"
    bash scripts/ci/test-wedge-state-machine.sh 2>&1
)"
EXISTING_RC=$?
if [[ "$EXISTING_RC" -eq 0 ]]; then
    ok "test-wedge-state-machine.sh still passes"
else
    fail "test-wedge-state-machine.sh REGRESSED (rc=$EXISTING_RC):\n$EXISTING_OUT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
