#!/usr/bin/env bash
# scripts/ci/test-daemon-exit-loop-watcher.sh — INFRA-2417
#
# Smoke test for daemon-exit-loop-watcher-daemon.sh:
#   1. Script presence + executable + bash-syntax clean
#   2. Plist + installer present and reference the script
#   3. CHUMP_DAEMON_EXIT_LOOP_DISABLED bypass: exits 0, emits kind=daemon_exit_loop_disabled
#   4. Detection path: mock launchctl returning last_exit_code=1, runs=5 →
#      assert kind=daemon_exit_loop_detected emitted with correct label + gap filed
#   5. Dedup path: second tick with same label → no new gap reserve
#   6. Recovery path: mock returns exit_code=0 → assert kind=daemon_exit_loop_recovered + gap closed
#   7. Under-threshold path: runs=2, exit=1 → assert NO detection event/gap
#   8. EVENT_REGISTRY.yaml registers all three new kinds

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DAEMON="$REPO_ROOT/scripts/coord/daemon-exit-loop-watcher-daemon.sh"
PLIST="$REPO_ROOT/scripts/launchd/com.chump.daemon-exit-loop-watcher.plist"
INSTALLER="$REPO_ROOT/scripts/setup/install-daemon-exit-loop-watcher-launchd.sh"

pass() { printf '  PASS: %s\n' "$*"; }
fail() { printf '  FAIL: %s\n' "$*" >&2; exit 1; }

echo "=== test-daemon-exit-loop-watcher.sh (INFRA-2417) ==="

# ── 1. Script presence + executable + syntax ──────────────────────────────────
echo "--- 1: source contract ---"
[[ -f "$DAEMON" ]]     || fail "daemon script missing: $DAEMON"
[[ -x "$DAEMON" ]]     || fail "daemon script not executable: $DAEMON"
bash -n "$DAEMON"      || fail "daemon bash -n failed"
[[ -f "$INSTALLER" ]]  || fail "installer missing: $INSTALLER"
[[ -x "$INSTALLER" ]]  || fail "installer not executable: $INSTALLER"
bash -n "$INSTALLER"   || fail "installer bash -n failed"
[[ -f "$PLIST" ]]      || fail "plist missing: $PLIST"
grep -q "daemon-exit-loop-watcher-daemon.sh" "$PLIST" \
    || fail "plist does not reference daemon-exit-loop-watcher-daemon.sh"
grep -q "com.chump.daemon-exit-loop-watcher" "$PLIST" \
    || fail "plist missing expected Label"
grep -q "StartInterval" "$PLIST" \
    || fail "plist missing StartInterval key"
grep -q "900" "$PLIST" \
    || fail "plist StartInterval must be 900 (15min)"
# INFRA-2417: plist must NOT reference /tmp or /private/tmp in functional elements
# (strip multi-line XML comments before checking; only <string> values matter)
plist_tmp_check="$(python3 -c "
import re, sys
content = open('$PLIST').read()
# Remove all XML comment blocks <!-- ... -->
stripped = re.sub(r'<!--.*?-->', '', content, flags=re.DOTALL)
# Only look at <string> element values
strings = re.findall(r'<string>(.*?)</string>', stripped, re.DOTALL)
for s in strings:
    if '/private/tmp' in s or '/tmp/' in s:
        print(s)
" 2>/dev/null || true)"
if [[ -n "$plist_tmp_check" ]]; then
    fail "plist <string> value contains ephemeral /tmp path — use stable /Users/.../Projects/Chump: $plist_tmp_check"
fi
pass "daemon + plist + installer present, syntax clean, stable path in plist"

# ── Shared temp setup ─────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
TMP_AMB="$TMP_DIR/ambient.jsonl"
TMP_STATE="$TMP_DIR/daemon-exit-loop-state.json"
STUB_DIR="$TMP_DIR/stubs"
mkdir -p "$STUB_DIR"
: > "$TMP_AMB"

STUB_LOG="$STUB_DIR/calls.log"
: > "$STUB_LOG"

# Write a stub chump binary that handles gap reserve/set
write_chump_stub() {
    local gap_id="${1:-INFRA-9990}"
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
    *)
        printf 'chump-stub: unhandled: %s\n' "\$*" >&2
        exit 0
        ;;
esac
STUBEOF
    chmod +x "$STUB_DIR/chump"
}

# Write a mock launchctl binary.
# Format of output lines it must contain:
#   state = not running
#   runs = <N>
#   last exit code = <E>
# Pass args: label state runs exit_code
# NOTE: `launchctl print gui/<uid>/<label>` passes "print" as $1 and
# "gui/<uid>/<label>" as $2 — match on $2, NOT $3.
write_launchctl_stub() {
    local label="$1" daemon_state="$2" runs="$3" exit_code="$4"
    cat > "$STUB_DIR/launchctl" <<STUBEOF
#!/usr/bin/env bash
# Mock launchctl for INFRA-2417 tests
# Usage: launchctl print gui/<uid>/<label>
# $1=print  $2=gui/<uid>/<label>
SERVICE="\${2:-unknown}"
case "\$SERVICE" in
    *${label}*)
        printf 'gui/501/${label} = {\n'
        printf '\tstate = ${daemon_state}\n'
        printf '\truns = ${runs}\n'
        printf '\tlast exit code = ${exit_code}\n'
        printf '}\n'
        ;;
    *)
        printf 'Could not find service: %s\n' "\$SERVICE" >&2
        exit 1
        ;;
esac
STUBEOF
    chmod +x "$STUB_DIR/launchctl"
}

# Write a stub bootstrap script that only declares one REQUIRED daemon: test-daemon
write_bootstrap_stub() {
    local label="$1"
    cat > "$STUB_DIR/chump-fleet-bootstrap.sh" <<STUBEOF
#!/usr/bin/env bash
REQUIRED_DAEMONS=(
    "${label}|scripts/setup/install-test-stub.sh"
)
STUBEOF
}

run_daemon() {
    : > "$STUB_LOG"
    : > "$TMP_AMB"
    CHUMP_DAEMON_EXIT_LOOP_CHUMP_CMD="$STUB_DIR/chump" \
    CHUMP_DAEMON_EXIT_LOOP_STATE_FILE="$TMP_STATE" \
    CHUMP_AMBIENT_PATH="$TMP_AMB" \
    CHUMP_DAEMON_MOCK_LAUNCHCTL="$STUB_DIR/launchctl" \
    CHUMP_DAEMON_EXIT_LOOP_BOOTSTRAP_SCRIPT="$STUB_DIR/chump-fleet-bootstrap.sh" \
    CHUMP_DAEMON_EXIT_LOOP_OPTIONAL_ALLOWLIST="$STUB_DIR/optional-installers-allowlist.txt" \
    REPO_ROOT="$STUB_DIR" \
        "$DAEMON" tick 2>&1
}

trap 'rm -rf "$TMP_DIR"' EXIT

# ── 2. DISABLED bypass ────────────────────────────────────────────────────────
echo "--- 2: CHUMP_DAEMON_EXIT_LOOP_DISABLED bypass ---"
: > "$TMP_AMB"
out="$(CHUMP_DAEMON_EXIT_LOOP_DISABLED=1 \
       CHUMP_AMBIENT_PATH="$TMP_AMB" \
       "$DAEMON" 2>&1)"
printf '%s\n' "$out" | grep -q "DISABLED" \
    || fail "bypass did not log DISABLED message; got: $out"
grep -q '"kind":"daemon_exit_loop_disabled"' "$TMP_AMB" \
    || fail "bypass must emit kind=daemon_exit_loop_disabled; ambient: $(cat "$TMP_AMB")"
# Must NOT emit detected or recovered when disabled
if grep -q '"kind":"daemon_exit_loop_detected"' "$TMP_AMB"; then
    fail "disabled path must not emit daemon_exit_loop_detected"
fi
pass "CHUMP_DAEMON_EXIT_LOOP_DISABLED=1 exits cleanly and emits disabled event"

# ── Set up stub environment for remaining tests ───────────────────────────────
# Use a fake label unique to these tests
TEST_LABEL="com.chump.test-fake-daemon"
write_bootstrap_stub "$TEST_LABEL"
# Create an empty optional allowlist stub (no entries that match fake label)
: > "$STUB_DIR/optional-installers-allowlist.txt"

# ── 3. Detection path: runs=5, exit=1 → kind=daemon_exit_loop_detected ────────
echo "--- 3: detection path (runs=5, exit=1, threshold=3) ---"
rm -f "$TMP_STATE"
write_chump_stub "INFRA-9990"
write_launchctl_stub "$TEST_LABEL" "not running" 5 1
out="$(CHUMP_DAEMON_EXIT_LOOP_THRESHOLD=3 run_daemon)"
# Must emit daemon_exit_loop_detected
grep -q '"kind":"daemon_exit_loop_detected"' "$TMP_AMB" \
    || fail "detection path did not emit kind=daemon_exit_loop_detected; ambient: $(cat "$TMP_AMB")"
# Label must appear in event
grep -q "\"label\":\"${TEST_LABEL}\"" "$TMP_AMB" \
    || fail "daemon_exit_loop_detected missing label field; ambient: $(cat "$TMP_AMB")"
# Gap reserve must have been called
grep -q "reserve" "$STUB_LOG" \
    || fail "detection path did not call chump gap reserve; calls: $(cat "$STUB_LOG")"
# Gap ID must appear in event
grep -q '"gap_id":"INFRA-9990"' "$TMP_AMB" \
    || fail "daemon_exit_loop_detected missing gap_id; ambient: $(cat "$TMP_AMB")"
# State file must record LOOP_DETECTED
[[ -f "$TMP_STATE" ]] || fail "state file not written on detection tick"
state_val="$(python3 -c "
import json
s = json.load(open('$TMP_STATE'))
fp = list(s.get('labels', {}).keys())
if fp:
    print(s['labels'][fp[0]].get('state', ''))
else:
    print('')
" 2>/dev/null)"
[[ "$state_val" == "LOOP_DETECTED" ]] || fail "label state not LOOP_DETECTED; got: $state_val"
pass "detection path: daemon_exit_loop_detected emitted with label + gap_id, state=LOOP_DETECTED"

# ── 4. Dedup path: second tick with same label → no new gap reserve ───────────
echo "--- 4: dedup (same label, second tick) ---"
: > "$STUB_LOG"
# launchctl stub still returns same exit=1; threshold=3; state has LOOP_DETECTED
out="$(CHUMP_DAEMON_EXIT_LOOP_THRESHOLD=3 run_daemon)"
# Reserve must NOT be called again (dedup via LOOP_DETECTED state)
if grep -q "reserve" "$STUB_LOG" 2>/dev/null; then
    fail "dedup path called gap reserve again; calls: $(cat "$STUB_LOG")"
fi
# daemon_exit_loop_detected must still be emitted each tick (with dedup=true)
grep -q '"kind":"daemon_exit_loop_detected"' "$TMP_AMB" \
    || fail "dedup path must still emit daemon_exit_loop_detected; ambient: $(cat "$TMP_AMB")"
pass "dedup: LOOP_DETECTED state → no second gap reserve"

# ── 5. Recovery path: exit=0 → kind=daemon_exit_loop_recovered + gap closed ───
echo "--- 5: recovery (exit=0 after LOOP_DETECTED) ---"
: > "$STUB_LOG"
write_launchctl_stub "$TEST_LABEL" "running" 6 0
out="$(CHUMP_DAEMON_EXIT_LOOP_THRESHOLD=3 run_daemon)"
grep -q '"kind":"daemon_exit_loop_recovered"' "$TMP_AMB" \
    || fail "recovery path did not emit kind=daemon_exit_loop_recovered; ambient: $(cat "$TMP_AMB")"
# chump gap set (close) must have been attempted for the filed gap
grep -q "gap set INFRA-9990" "$STUB_LOG" \
    || fail "recovery path did not close gap INFRA-9990; calls: $(cat "$STUB_LOG")"
# State should be OK now
state_val="$(python3 -c "
import json
s = json.load(open('$TMP_STATE'))
fp = list(s.get('labels', {}).keys())
if fp:
    print(s['labels'][fp[0]].get('state', ''))
else:
    print('')
" 2>/dev/null)"
[[ "$state_val" == "OK" ]] || fail "label state not OK after recovery; got: $state_val"
pass "recovery: daemon_exit_loop_recovered emitted, gap closed, state=OK"

# ── 6. Under-threshold path: runs=2, exit=1 → NO detection event ─────────────
echo "--- 6: under-threshold (runs=2, exit=1, threshold=3) ---"
rm -f "$TMP_STATE"
: > "$STUB_LOG"
: > "$TMP_AMB"
write_chump_stub "INFRA-9991"
write_launchctl_stub "$TEST_LABEL" "not running" 2 1
out="$(CHUMP_DAEMON_EXIT_LOOP_THRESHOLD=3 run_daemon)"
# Must NOT emit daemon_exit_loop_detected
if grep -q '"kind":"daemon_exit_loop_detected"' "$TMP_AMB"; then
    fail "under-threshold path must NOT emit daemon_exit_loop_detected; ambient: $(cat "$TMP_AMB")"
fi
# Must NOT file a gap
if grep -q "reserve" "$STUB_LOG"; then
    fail "under-threshold path must NOT call gap reserve; calls: $(cat "$STUB_LOG")"
fi
pass "under-threshold: runs=2 < threshold=3 → no event, no gap"

# ── 7. EVENT_REGISTRY.yaml covers all three new kinds ─────────────────────────
echo "--- 7: EVENT_REGISTRY.yaml coverage ---"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
for kind in daemon_exit_loop_detected daemon_exit_loop_recovered daemon_exit_loop_disabled; do
    grep -q "kind: ${kind}" "$REGISTRY" \
        || fail "EVENT_REGISTRY.yaml missing kind: ${kind}"
done
pass "all three new event kinds registered in EVENT_REGISTRY.yaml"

printf '\n=== test-daemon-exit-loop-watcher.sh PASSED ===\n'
