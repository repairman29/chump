#!/usr/bin/env bash
# test-bootstrap-auto-install.sh — INFRA-1808
#
# Verifies the hourly auto-bootstrap launchd job:
#   1. install-bootstrap-auto-launchd.sh exists + executable
#   2. installer writes a valid plist into a temp $HOME (stubbed launchctl,
#      never touches the real system launchd)
#   3. plist Label / StartInterval / ProgramArguments are correct
#   4. plist ProgramArguments invokes chump-fleet-bootstrap.sh --auto-tick
#   5. the manifest has an entry for bootstrap-auto-launchd (so the FIRST
#      manual bootstrap run self-installs the hourly job — AC 6)
#   6. a synthetic `chump-fleet-bootstrap.sh --auto-tick` run emits
#      kind=fleet_bootstrap_auto_install with the expected fields

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/install-bootstrap-auto-launchd.sh"
BOOTSTRAP="$REPO_ROOT/scripts/setup/chump-fleet-bootstrap.sh"
MANIFEST="$REPO_ROOT/scripts/setup/bootstrap-manifest.yaml"

echo "=== INFRA-1808 bootstrap-auto-install test ==="

[[ -x "$INSTALLER" ]] || { fail "installer not found/executable: $INSTALLER"; }
ok "install-bootstrap-auto-launchd.sh exists and is executable"

# Stub launchctl so the installer never touches the real system launchd.
TMP_HOME="$(mktemp -d -t bootstrap-auto-install-home-XXXX)"
TMP_BIN="$(mktemp -d -t bootstrap-auto-install-bin-XXXX)"
trap 'rm -rf "$TMP_HOME" "$TMP_BIN"' EXIT
mkdir -p "$TMP_HOME/Library/LaunchAgents"
cat >"$TMP_BIN/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "[stub-launchctl] $*"
exit 0
STUB
chmod +x "$TMP_BIN/launchctl"

if HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" bash "$INSTALLER" >/dev/null 2>&1; then
    ok "installer runs clean against a temp HOME (stubbed launchctl)"
else
    fail "installer exited non-zero against temp HOME"
fi

PLIST="$TMP_HOME/Library/LaunchAgents/dev.chump.bootstrap-auto-install.plist"
if [[ -f "$PLIST" ]]; then
    ok "installer wrote plist to \$HOME/Library/LaunchAgents/"
else
    fail "plist not written at $PLIST"
fi

if [[ -f "$PLIST" ]]; then
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$PLIST" >/dev/null 2>&1 && ok "plist passes plutil -lint" || fail "plist failed plutil -lint"
    else
        python3 -c "import xml.etree.ElementTree as ET; ET.parse('$PLIST')" 2>/dev/null \
            && ok "plist parses as XML" || fail "plist is not valid XML"
    fi

    grep -A1 "<key>Label</key>" "$PLIST" | grep -q "dev.chump.bootstrap-auto-install" \
        && ok "plist Label = dev.chump.bootstrap-auto-install" \
        || fail "plist Label mismatch"

    grep -A1 "<key>StartInterval</key>" "$PLIST" | grep -q "<integer>3600</integer>" \
        && ok "plist StartInterval = 3600 (hourly)" \
        || fail "plist StartInterval is not 3600"

    grep -q "chump-fleet-bootstrap.sh --auto-tick" "$PLIST" \
        && ok "plist ProgramArguments invokes chump-fleet-bootstrap.sh --auto-tick" \
        || fail "plist does not invoke chump-fleet-bootstrap.sh --auto-tick"
fi

# AC 6: manifest has an entry so the bootstrap self-installs this job.
if python3 -c "
import yaml, sys
data = yaml.safe_load(open('$MANIFEST'))
ids = [e.get('id') for e in data.get('installers', [])]
sys.exit(0 if 'bootstrap-auto-launchd' in ids else 1)
"; then
    ok "manifest has bootstrap-auto-launchd entry (self-installs on first run)"
else
    fail "manifest missing bootstrap-auto-launchd entry"
fi

# AC 9: synthetic --auto-tick run emits kind=fleet_bootstrap_auto_install
# with the expected fields. Use --only with a bogus id so no real installer
# runs; the ambient emit fires regardless of INSTALLED count.
AMBIENT_TMP="$(mktemp -d -t bootstrap-auto-install-ambient-XXXX)/ambient.jsonl"
mkdir -p "$(dirname "$AMBIENT_TMP")"
CHUMP_AMBIENT_LOG="$AMBIENT_TMP" PATH="$TMP_BIN:$PATH" \
    bash "$BOOTSTRAP" --check --auto-tick --only __nonexistent-id__ >/dev/null 2>&1 || true

if grep -q '"kind":"fleet_bootstrap_auto_install"' "$AMBIENT_TMP" 2>/dev/null; then
    ok "--auto-tick emits kind=fleet_bootstrap_auto_install"
    line="$(grep '"kind":"fleet_bootstrap_auto_install"' "$AMBIENT_TMP" | tail -1)"
    for field in installed_count manifest_missing_count daemon_missing_count; do
        if echo "$line" | grep -q "\"$field\""; then
            ok "event has field $field"
        else
            fail "event missing field $field (line: $line)"
        fi
    done
else
    fail "ambient missing kind=fleet_bootstrap_auto_install after --auto-tick run"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
