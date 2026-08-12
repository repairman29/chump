#!/usr/bin/env bash
# test-bootstrap-auto-install.sh — INFRA-1808
#
# Smoke test for install-bootstrap-auto-launchd.sh + the
# bootstrap-auto-install-runner.sh it schedules hourly.
#
# Runs in dry-run mode (no launchctl calls — safe on Linux CI):
#   1. install --dry-run generates a plist with the right shape
#      (Label, StartInterval=3600, ProgramArguments -> runner script)
#   2. the runner script passes bash -n
#   3. a synthetic invocation of the runner (against a stub
#      chump-fleet-bootstrap.sh) emits kind=fleet_bootstrap_auto_install
#      with installed_count/manifest_missing_count/daemon_missing_count

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/scripts/setup/install-bootstrap-auto-launchd.sh"
RUNNER="$REPO_ROOT/scripts/setup/bootstrap-auto-install-runner.sh"

PASS=0
FAIL=0
FAILS=()
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILS+=("$1"); echo "FAIL  $1"; }

echo "=== INFRA-1808 bootstrap-auto-install test ==="

[[ -f "$INSTALL_SCRIPT" ]] || { echo "FATAL: $INSTALL_SCRIPT missing"; exit 2; }
[[ -f "$RUNNER" ]] || { echo "FATAL: $RUNNER missing"; exit 2; }

bash -n "$INSTALL_SCRIPT" && pass "install-bootstrap-auto-launchd.sh passes bash -n" || fail "install-bootstrap-auto-launchd.sh syntax error"
bash -n "$RUNNER" && pass "bootstrap-auto-install-runner.sh passes bash -n" || fail "bootstrap-auto-install-runner.sh syntax error"

# --- Test: --dry-run generates a well-formed plist (no launchctl call) ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Library/LaunchAgents"

CHUMP_LAUNCH_AGENTS_DIR="$TMP/Library/LaunchAgents" bash "$INSTALL_SCRIPT" --dry-run >/tmp/bootstrap-auto-install-dry.log 2>&1
DRY_RC=$?
PLIST="$TMP/Library/LaunchAgents/com.chump.bootstrap-auto-install.plist"

if [[ "$DRY_RC" -eq 0 ]]; then pass "install --dry-run exited 0"; else fail "install --dry-run exited $DRY_RC"; fi
if [[ -f "$PLIST" ]]; then pass "plist generated at $PLIST"; else fail "plist NOT generated (expected $PLIST)"; fi

if [[ -f "$PLIST" ]]; then
    grep -q '<string>com.chump.bootstrap-auto-install</string>' "$PLIST" && pass "plist Label=com.chump.bootstrap-auto-install" || fail "plist missing correct Label"
    grep -A1 'StartInterval' "$PLIST" | grep -q '<integer>3600</integer>' && pass "plist StartInterval=3600 (hourly)" || fail "plist StartInterval != 3600"
    grep -q "bootstrap-auto-install-runner.sh" "$PLIST" && pass "plist ProgramArguments references bootstrap-auto-install-runner.sh" || fail "plist does not reference runner script"
fi

# --- Test: runner emits kind=fleet_bootstrap_auto_install with expected fields ---
STUB_DIR="$(mktemp -d)"
mkdir -p "$STUB_DIR/scripts/setup" "$STUB_DIR/.chump-locks"
cat >"$STUB_DIR/scripts/setup/chump-fleet-bootstrap.sh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--install" ]]; then
    echo "=== bootstrap done: 2 installed, 5 already healthy, 0 failed"
    exit 0
fi
if [[ "$1" == "--check" ]]; then
    echo "=== bootstrap audit: 5 installed, 1 manifest-missing, 3 daemon-missing"
    exit 1
fi
STUB
chmod +x "$STUB_DIR/scripts/setup/chump-fleet-bootstrap.sh"

AMBIENT_LOG="$STUB_DIR/.chump-locks/ambient.jsonl"
CHUMP_BOOTSTRAP_SCRIPT="$STUB_DIR/scripts/setup/chump-fleet-bootstrap.sh" \
CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$RUNNER" >/tmp/bootstrap-auto-install-runner.log 2>&1
RUNNER_RC=$?

if [[ "$RUNNER_RC" -eq 0 ]]; then pass "runner exited 0 against stub bootstrap"; else fail "runner exited $RUNNER_RC"; fi

if grep -q '"kind":"fleet_bootstrap_auto_install"' "$AMBIENT_LOG" 2>/dev/null; then
    pass "runner emits kind=fleet_bootstrap_auto_install"
    EVENT_LINE="$(grep '"kind":"fleet_bootstrap_auto_install"' "$AMBIENT_LOG" | tail -1)"
    for field in installed_count manifest_missing_count daemon_missing_count; do
        if echo "$EVENT_LINE" | grep -q "\"$field\":"; then
            pass "event has field $field"
        else
            fail "event missing field $field"
        fi
    done
    if echo "$EVENT_LINE" | grep -q '"installed_count":2' && \
       echo "$EVENT_LINE" | grep -q '"manifest_missing_count":1' && \
       echo "$EVENT_LINE" | grep -q '"daemon_missing_count":3'; then
        pass "event fields parsed correctly from stub output (2/1/3)"
    else
        fail "event fields did not match stub output (expected 2/1/3): $EVENT_LINE"
    fi
else
    fail "ambient log missing kind=fleet_bootstrap_auto_install"
fi

rm -rf "$STUB_DIR"

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "PASS"
