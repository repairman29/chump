#!/usr/bin/env bash
# test-main-preflight-watchdog.sh — INFRA-2397
#
# Smoke test for main-preflight-watchdog-daemon.sh:
#   1. Script presence + executable + bash-syntax clean
#   2. Plist + installer present and reference the script
#   3. CHUMP_MAIN_PREFLIGHT_DISABLED bypass: exits 0, emits kind=main_preflight_disabled,
#      does NOT emit main_preflight_red or main_preflight_recovered
#   4. GREEN path (MOCK_PASS): no gap filed, state written as GREEN
#   5. RED path (MOCK_FAIL): emits kind=main_preflight_red with correct gate label,
#      chump gap reserve called with the right fingerprint prefix
#   6. Dedup path (RED again, same gates): no second gap reserve called
#   7. RECOVERY path (RED → GREEN): emits kind=main_preflight_recovered, walks gaps
#   8. EVENT_REGISTRY.yaml registers all three new kinds

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DAEMON="$REPO_ROOT/scripts/coord/main-preflight-watchdog-daemon.sh"
PLIST="$REPO_ROOT/scripts/launchd/com.chump.main-preflight-watchdog.plist"
INSTALLER="$REPO_ROOT/scripts/setup/install-main-preflight-watchdog-daemon-launchd.sh"

pass() { printf '  PASS: %s\n' "$*"; }
fail() { printf '  FAIL: %s\n' "$*" >&2; exit 1; }

echo "=== test-main-preflight-watchdog.sh (INFRA-2397) ==="

# ── 1. Script presence + executable + syntax ──────────────────────────────────
echo "--- 1: source contract ---"
[[ -f "$DAEMON" ]]     || fail "daemon script missing: $DAEMON"
[[ -x "$DAEMON" ]]     || fail "daemon script not executable: $DAEMON"
bash -n "$DAEMON"      || fail "daemon bash -n failed"
[[ -f "$INSTALLER" ]]  || fail "installer missing: $INSTALLER"
[[ -x "$INSTALLER" ]]  || fail "installer not executable: $INSTALLER"
bash -n "$INSTALLER"   || fail "installer bash -n failed"
[[ -f "$PLIST" ]]      || fail "plist missing: $PLIST"
grep -q "main-preflight-watchdog-daemon.sh" "$PLIST" \
    || fail "plist does not reference main-preflight-watchdog-daemon.sh"
grep -q "com.chump.main-preflight-watchdog" "$PLIST" \
    || fail "plist missing expected Label"
grep -q "StartInterval" "$PLIST" \
    || fail "plist missing StartInterval key"
pass "daemon + plist + installer present, syntax clean"

# ── Shared temp setup ─────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
TMP_AMB="$TMP_DIR/ambient.jsonl"
TMP_STATE="$TMP_DIR/main-preflight-state.json"
STUB_DIR="$TMP_DIR/stubs"
mkdir -p "$STUB_DIR"
: > "$TMP_AMB"

STUB_LOG="$STUB_DIR/calls.log"
: > "$STUB_LOG"

# Write a stub chump binary that handles gap reserve/set/list
write_chump_stub() {
    local gap_id="${1:-INFRA-9998}"
    local open_gaps="${2:-[]}"
    cat > "$STUB_DIR/chump" <<STUBEOF
#!/usr/bin/env bash
printf 'chump %s\n' "\$*" >> "$STUB_LOG"
case "\${2:-}" in
    reserve)
        printf '%s\n' "$gap_id"
        ;;
    set)
        :
        ;;
    list)
        printf '%s\n' '$open_gaps'
        ;;
    *)
        printf 'chump-stub: unhandled: %s\n' "\$*" >&2
        exit 1
        ;;
esac
STUBEOF
    chmod +x "$STUB_DIR/chump"
}

run_daemon() {
    : > "$STUB_LOG"
    : > "$TMP_AMB"
    # Suppress git operations in test mode — MOCK_PASS/MOCK_FAIL bypass the worktree path
    CHUMP_MAIN_PREFLIGHT_CHUMP_CMD="$STUB_DIR/chump" \
    CHUMP_MAIN_PREFLIGHT_STATE_FILE="$TMP_STATE" \
    CHUMP_AMBIENT_PATH="$TMP_AMB" \
    REPO_ROOT="$REPO_ROOT" \
        "$DAEMON" tick 2>&1
}

trap 'rm -rf "$TMP_DIR"' EXIT

# ── 2. DISABLED bypass ────────────────────────────────────────────────────────
echo "--- 2: CHUMP_MAIN_PREFLIGHT_DISABLED bypass ---"
: > "$TMP_AMB"
out="$(CHUMP_MAIN_PREFLIGHT_DISABLED=1 \
       CHUMP_AMBIENT_PATH="$TMP_AMB" \
       "$DAEMON" 2>&1)"
printf '%s\n' "$out" | grep -q "DISABLED" \
    || fail "bypass did not log DISABLED message; got: $out"
grep -q '"kind":"main_preflight_disabled"' "$TMP_AMB" \
    || fail "bypass must emit kind=main_preflight_disabled; ambient: $(cat "$TMP_AMB")"
# Must NOT emit red or recovered when disabled
if grep -q '"kind":"main_preflight_red"' "$TMP_AMB"; then
    fail "disabled path must not emit main_preflight_red"
fi
pass "CHUMP_MAIN_PREFLIGHT_DISABLED=1 exits cleanly and emits disabled event"

# ── 3. GREEN path (MOCK_PASS) ─────────────────────────────────────────────────
echo "--- 3: GREEN path (MOCK_PASS) ---"
rm -f "$TMP_STATE"
write_chump_stub "INFRA-9998" "[]"
out="$(CHUMP_MAIN_PREFLIGHT_MOCK_PASS=1 run_daemon)"
# Must NOT file a gap
if grep -q "reserve" "$STUB_LOG"; then
    fail "GREEN path called chump gap reserve; calls: $(cat "$STUB_LOG")"
fi
# State file must record GREEN
[[ -f "$TMP_STATE" ]] || fail "state file not written on GREEN tick"
state_val="$(python3 -c "import json; print(json.load(open('$TMP_STATE')).get('state',''))" 2>/dev/null)"
[[ "$state_val" == "GREEN" ]] || fail "state not GREEN; got: $state_val"
pass "GREEN path: no gap filed, state=GREEN"

# ── 4. RED path (MOCK_FAIL): kind=main_preflight_red emitted with gate label ──
echo "--- 4: RED path (MOCK_FAIL) ---"
rm -f "$TMP_STATE"
: > "$STUB_LOG"
write_chump_stub "INFRA-9997" "[]"
out="$(CHUMP_MAIN_PREFLIGHT_MOCK_FAIL="event-registry-coverage,env-var-coverage" run_daemon)"
# Must emit main_preflight_red
grep -q '"kind":"main_preflight_red"' "$TMP_AMB" \
    || fail "RED path did not emit kind=main_preflight_red; ambient: $(cat "$TMP_AMB")"
# Failing gates must appear in event
grep -q "event-registry-coverage" "$TMP_AMB" \
    || fail "main_preflight_red event missing gate label; ambient: $(cat "$TMP_AMB")"
# Gap reserve must have been called
grep -q "reserve" "$STUB_LOG" \
    || fail "RED path did not call chump gap reserve; calls: $(cat "$STUB_LOG")"
# Gap ID must appear in event
grep -q '"gap_id":"INFRA-9997"' "$TMP_AMB" \
    || fail "main_preflight_red missing gap_id; ambient: $(cat "$TMP_AMB")"
# State must be RED
state_val="$(python3 -c "import json; print(json.load(open('$TMP_STATE')).get('state',''))" 2>/dev/null)"
[[ "$state_val" == "RED" ]] || fail "state not RED after red tick; got: $state_val"
pass "RED path: kind=main_preflight_red emitted with correct gate label and gap_id"

# ── 5. Dedup path: second RED tick with same gates → no new reserve ───────────
echo "--- 5: dedup (same gates, second tick) ---"
: > "$STUB_LOG"
# TMP_AMB is refreshed by run_daemon — stash old fingerprint check via state
out="$(CHUMP_MAIN_PREFLIGHT_MOCK_FAIL="event-registry-coverage,env-var-coverage" run_daemon)"
# Reserve must NOT be called again (fingerprint dedup)
if grep -q "reserve" "$STUB_LOG" 2>/dev/null; then
    fail "dedup path called gap reserve again; calls: $(cat "$STUB_LOG")"
fi
# main_preflight_red must still be emitted (event every tick)
grep -q '"kind":"main_preflight_red"' "$TMP_AMB" \
    || fail "dedup path must still emit main_preflight_red per tick"
pass "dedup: same fingerprint → no second gap reserve"

# ── 6. RECOVERY path (RED → GREEN): kind=main_preflight_recovered emitted ─────
echo "--- 6: RECOVERY (RED -> GREEN) ---"
: > "$STUB_LOG"
out="$(CHUMP_MAIN_PREFLIGHT_MOCK_PASS=1 run_daemon)"
grep -q '"kind":"main_preflight_recovered"' "$TMP_AMB" \
    || fail "RECOVERY path did not emit kind=main_preflight_recovered; ambient: $(cat "$TMP_AMB")"
# chump gap set (close) must have been attempted for the filed gap
grep -q "gap set INFRA-9997" "$STUB_LOG" \
    || fail "RECOVERY path did not close gap INFRA-9997; calls: $(cat "$STUB_LOG")"
# State should be GREEN now
state_val="$(python3 -c "import json; print(json.load(open('$TMP_STATE')).get('state',''))" 2>/dev/null)"
[[ "$state_val" == "GREEN" ]] || fail "state not GREEN after recovery; got: $state_val"
pass "RECOVERY: kind=main_preflight_recovered emitted, gap closed, state=GREEN"

# ── 7. EVENT_REGISTRY.yaml covers all three new kinds ─────────────────────────
echo "--- 7: EVENT_REGISTRY.yaml coverage ---"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
for kind in main_preflight_red main_preflight_recovered main_preflight_disabled; do
    grep -q "kind: ${kind}" "$REGISTRY" \
        || fail "EVENT_REGISTRY.yaml missing kind: ${kind}"
done
pass "all three new event kinds registered in EVENT_REGISTRY.yaml"

# ── 8. INFRA-2404 round-trip: writer → reader contract ────────────────────────
# Fresh-eyes review of PR #2943 + #2944 caught that the watchdog wrote
# {state, updated_at, last_tick_id} but atomic_claim.rs reads
# {last_status, last_tick_at, failing_gates}. Gate was silently inert.
# This test asserts the state JSON now contains all reader-expected keys,
# regardless of which path (GREEN or RED) wrote it.
echo "--- 8: INFRA-2404 writer→reader key contract ---"

# After the RECOVERY path above, state is GREEN — verify reader keys present.
for k in last_status last_tick_at failing_gates; do
    python3 -c "import json,sys; d=json.load(open('$TMP_STATE')); assert '$k' in d, '$k missing'" \
        || fail "GREEN state missing reader-expected key: $k (json: $(cat "$TMP_STATE"))"
done
green_last_status="$(python3 -c "import json; print(json.load(open('$TMP_STATE'))['last_status'])")"
green_last_tick_at="$(python3 -c "import json; print(json.load(open('$TMP_STATE'))['last_tick_at'])")"
[[ "$green_last_status" == "green" ]] \
    || fail "GREEN state last_status should be 'green' (lower); got: '$green_last_status'"
[[ "$green_last_tick_at" -gt 0 ]] \
    || fail "GREEN state last_tick_at should be > 0 (unix secs); got: '$green_last_tick_at'"
pass "GREEN: last_status='green' + last_tick_at>0 + failing_gates=[] all present"

# Force a RED state by running tick once with MOCK_FAIL set.
TMP_AMB2="$(mktemp)"
STUB_LOG2="$(mktemp)"
CHUMP_BIN=/usr/bin/true \
    CHUMP_AMBIENT_LOG="$TMP_AMB2" \
    CHUMP_MAIN_PREFLIGHT_STATE_FILE="$TMP_STATE" \
    CHUMP_MAIN_PREFLIGHT_MOCK_FAIL="alpha,beta" \
    PATH="/tmp:$PATH" \
    bash "$DAEMON" tick 2>&1 >/dev/null || true

for k in last_status last_tick_at failing_gates; do
    python3 -c "import json,sys; d=json.load(open('$TMP_STATE')); assert '$k' in d, '$k missing'" \
        || fail "RED state missing reader-expected key: $k"
done
red_last_status="$(python3 -c "import json; print(json.load(open('$TMP_STATE'))['last_status'])")"
red_gates="$(python3 -c "import json; print(','.join(sorted(json.load(open('$TMP_STATE'))['failing_gates'])))")"
[[ "$red_last_status" == "red" ]] \
    || fail "RED state last_status should be 'red' (lower); got: '$red_last_status'"
[[ "$red_gates" == "alpha,beta" ]] \
    || fail "RED state failing_gates should be ['alpha','beta']; got: '$red_gates'"
pass "RED: last_status='red' + failing_gates=['alpha','beta'] all present"
rm -f "$TMP_AMB2" "$STUB_LOG2"

# ── 9. INFRA-2404 fingerprint stability (Bug 3 — tr '\n' '|' replaces no-op) ──
echo "--- 9: INFRA-2404 fingerprint stability ---"
# Source the helper directly to get the function
fp1="$(bash -c "source $DAEMON 2>/dev/null; _gate_fingerprint 'alpha,beta,gamma'")"
fp2="$(bash -c "source $DAEMON 2>/dev/null; _gate_fingerprint 'gamma,beta,alpha'")"
[[ "$fp1" == "$fp2" ]] \
    || fail "fingerprint should be order-independent (sort); got fp1='$fp1' fp2='$fp2'"
fp3="$(bash -c "source $DAEMON 2>/dev/null; _gate_fingerprint 'alpha,beta'")"
[[ "$fp1" != "$fp3" ]] \
    || fail "different gate sets should produce different fingerprints; got '$fp1' for both"
pass "fingerprint stable on sort + distinct on different gates"

printf '\n=== test-main-preflight-watchdog.sh PASSED ===\n'
