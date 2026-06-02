#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# test-ci-health-gate.sh — INFRA-1607
#
# Smoke tests for the CI health gate daemon + gap reserve guard:
#  1. ci-health-gate.sh script exists and is executable
#  2. CHUMP_CI_HEALTH_GATE_DISABLE=1 causes noop exit
#  3. ci-health-gate.sh writes fleet-paused when SLO check fails
#  4. chump gap reserve SUCCEEDS even when fleet-paused exists (INFRA-2424: reserve never blocks)
#  5. (removed — CHUMP_IGNORE_WASTE_PAUSE bypass deleted by INFRA-2424)
#  6. launchd plist exists with StartInterval=300
#  7. bootstrap-manifest.yaml has ci-health-gate-launchd entry
#  8. EVENT_REGISTRY.yaml has pipeline_health_throttle + gap_reserve_blocked
#  9. FLEET_SLOS.md has L4-SLO-1 entry
# 10. worker.sh fleet-paused check is still intact (INFRA-2424: claim still blocks)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/ci-health-gate.sh"
TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

echo "=== INFRA-1607 ci-health-gate smoke test ==="
echo

# ── 1. Script exists and is executable ────────────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "ci-health-gate.sh exists and is executable"
else
    fail "ci-health-gate.sh missing or not executable at $SCRIPT"
fi

# ── 2. CHUMP_CI_HEALTH_GATE_DISABLE=1 → noop (exit 0, no pause file written) ─
PAUSE_FILE_2="$TMPDIR_LOCAL/fleet-paused-2"
CHUMP_CI_HEALTH_GATE_DISABLE=1 \
    CHUMP_FLEET_PAUSE_FILE="$PAUSE_FILE_2" \
    CHUMP_AMBIENT_LOG="$TMPDIR_LOCAL/ambient-2.jsonl" \
    bash "$SCRIPT" >"$TMPDIR_LOCAL/out2.txt" 2>&1 && rc2=0 || rc2=$?
if [[ $rc2 -eq 0 && ! -f "$PAUSE_FILE_2" ]]; then
    ok "CHUMP_CI_HEALTH_GATE_DISABLE=1 exits 0 without writing pause file"
else
    fail "CHUMP_CI_HEALTH_GATE_DISABLE=1 did not behave as noop (rc=$rc2 pause_exists=$(test -f "$PAUSE_FILE_2" && echo yes || echo no))"
fi

# ── 3. SLO failure → fleet-paused written ─────────────────────────────────────
# Stub chump health --slo-check to return exit 1.
FAKE_BIN="$TMPDIR_LOCAL/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/chump" <<'STUB'
#!/usr/bin/env bash
# Stub: chump health --slo-check always fails
if [[ "$1" == "health" && "$2" == "--slo-check" ]]; then
    exit 1
fi
exit 0
STUB
chmod +x "$FAKE_BIN/chump"

PAUSE_FILE_3="$TMPDIR_LOCAL/fleet-paused-3"
CONSEC_FILE_3="$TMPDIR_LOCAL/ci-health-recovery-3"
# Export PATH so the subprocess bash inherits the stub chump binary.
_saved_path="$PATH"
export PATH="$FAKE_BIN:$PATH"
CHUMP_FLEET_PAUSE_FILE="$PAUSE_FILE_3" \
    CHUMP_CI_HEALTH_CONSEC_FILE="$CONSEC_FILE_3" \
    CHUMP_AMBIENT_LOG="$TMPDIR_LOCAL/ambient-3.jsonl" \
    bash "$SCRIPT" 2>/dev/null && rc3=0 || rc3=$?
export PATH="$_saved_path"
if [[ -f "$PAUSE_FILE_3" ]]; then
    # Validate JSON shape
    if command -v python3 >/dev/null 2>&1; then
        reason="$(python3 -c "import json,sys; d=json.load(open('$PAUSE_FILE_3')); print(d['reason'])" 2>/dev/null || echo MISSING)"
        if [[ "$reason" == "slo_breach" ]]; then
            ok "SLO failure writes fleet-paused with reason=slo_breach"
        else
            fail "fleet-paused written but reason='$reason' (expected slo_breach)"
        fi
    else
        ok "fleet-paused written on SLO failure (python3 not available for JSON check)"
    fi
else
    fail "SLO failure did not write fleet-paused (rc=$rc3)"
fi

# ── 4. chump gap reserve SUCCEEDS even when fleet-paused exists (INFRA-2424) ──
# Reserve is unconditional — gaps are inert until claimed. The fleet-paused
# sentinel must NOT block filing; it only blocks chump claim (work dispatch).
CHUMP_BIN="$REPO_ROOT/target/debug/chump"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  [skip 4] chump binary not built — run: cargo build 2>/dev/null"
    SKIP_BINARY=1
else
    SKIP_BINARY=0
fi

if [[ "${SKIP_BINARY:-0}" -eq 0 ]]; then
    PAUSE_FILE_4="$TMPDIR_LOCAL/fleet-paused-4"
    # Write a valid slo_breach payload
    printf '{"ts":"2026-01-01T00:00:00Z","kind":"slo_breach","reason":"pipeline_jam","slos_breached":[],"blocked_pct":75}\n' \
        > "$PAUSE_FILE_4"

    stderr_out="$TMPDIR_LOCAL/reserve-stderr-4.txt"
    # reserve should succeed (exit 0) even with fleet-paused present
    CHUMP_FLEET_PAUSE_FILE="$PAUSE_FILE_4" \
        CHUMP_REPO="$REPO_ROOT" \
        CHUMP_ALLOW_MAIN_WORKTREE=1 \
        CHUMP_GAP_RESERVE_SKIP_PR=1 \
        CHUMP_RESERVE_NO_AUTOSTAGE=1 \
        CHUMP_PILLAR_BALANCE_DISABLE=1 \
        CHUMP_GAP_RESERVE_NO_SIMILARITY=1 \
        CHUMP_DISABLE_OFFLINE_CHECK=1 \
        "$CHUMP_BIN" gap reserve --domain TEST --title "test gap INFRA-2424 reserve-unblocked" \
        --skip-obs-acs --quiet \
        2>"$stderr_out" && rc4=0 || rc4=$?

    if [[ $rc4 -eq 0 ]]; then
        ok "chump gap reserve exits 0 even when fleet-paused exists (INFRA-2424)"
    else
        fail "chump gap reserve returned rc=$rc4 with fleet-paused — should be 0 (INFRA-2424 regression)"
    fi

    if grep -q "fleet is paused" "$stderr_out" 2>/dev/null; then
        fail "reserve emitted 'fleet is paused' — guard should have been removed (INFRA-2424)"
    else
        ok "reserve does not emit 'fleet is paused' with fleet-paused present (INFRA-2424)"
    fi

    # ── 5. (removed) CHUMP_IGNORE_WASTE_PAUSE deleted by INFRA-2424 ──────────
    # The bypass var no longer exists. Reserve is unconditional; claim enforces
    # the pause. No test needed here — test-slo-breach-gates.sh covers the
    # claim-blocks / reserve-succeeds split exhaustively.
fi

# ── 6. launchd plist exists with StartInterval=300 ────────────────────────────
PLIST="$REPO_ROOT/launchd/com.chump.ci-health-gate.plist"
if [[ -f "$PLIST" ]]; then
    ok "com.chump.ci-health-gate.plist exists"
    if grep -q "300" "$PLIST"; then
        ok "plist has StartInterval 300"
    else
        fail "plist missing StartInterval 300"
    fi
else
    fail "com.chump.ci-health-gate.plist missing"
fi

# ── 7. bootstrap-manifest.yaml has ci-health-gate-launchd entry ───────────────
MANIFEST="$REPO_ROOT/scripts/setup/bootstrap-manifest.yaml"
if grep -q "ci-health-gate-launchd" "$MANIFEST"; then
    ok "bootstrap-manifest.yaml has ci-health-gate-launchd entry"
else
    fail "bootstrap-manifest.yaml missing ci-health-gate-launchd entry"
fi

# ── 8. EVENT_REGISTRY.yaml has both new event kinds ───────────────────────────
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "pipeline_health_throttle" "$REGISTRY"; then
    ok "EVENT_REGISTRY.yaml has pipeline_health_throttle"
else
    fail "EVENT_REGISTRY.yaml missing pipeline_health_throttle"
fi
if grep -q "gap_reserve_blocked" "$REGISTRY"; then
    ok "EVENT_REGISTRY.yaml has gap_reserve_blocked"
else
    fail "EVENT_REGISTRY.yaml missing gap_reserve_blocked"
fi

# ── 9. FLEET_SLOS.md has L4-SLO-1 ────────────────────────────────────────────
SLOS="$REPO_ROOT/docs/process/FLEET_SLOS.md"
if grep -q "L4-SLO-1" "$SLOS"; then
    ok "FLEET_SLOS.md has L4-SLO-1 pipeline jam entry"
else
    fail "FLEET_SLOS.md missing L4-SLO-1"
fi

# ── 10. worker.sh fleet-paused check still intact for claim (INFRA-2424) ─────
# INFRA-2424: worker claim cycle still respects fleet-paused (only reserve is
# unconditional). The bypass env var is gone; the sentinel check remains.
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
if grep -q "fleet-paused" "$WORKER"; then
    ok "worker.sh fleet-paused sentinel check intact (claim still blocked)"
else
    fail "worker.sh fleet-paused sentinel check missing — claim guard regressed"
fi
if grep -q "CHUMP_IGNORE_WASTE_PAUSE" "$WORKER"; then
    fail "worker.sh still references CHUMP_IGNORE_WASTE_PAUSE — bypass not deleted (INFRA-2424)"
else
    ok "worker.sh does not reference CHUMP_IGNORE_WASTE_PAUSE — bypass correctly removed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
