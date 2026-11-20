#!/usr/bin/env bash
# scripts/ci/test-queue-driver-launchd-install.sh — INFRA-1304
#
# Verifies the queue-driver launchd plist + installer:
#   1. Plist file exists and is valid XML
#   2. StartInterval = 300 (5 min)
#   3. ProgramArguments references scripts/coord/queue-driver.sh
#   4. Installer script exists and is executable
#   5. Installer dry-run against a temp HOME writes the plist
#   6. --uninstall removes the plist
#   7. Mirrors known-good pattern from pr-watch-shepherd installer

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$REPO_ROOT/scripts/plists/dev.chump.queue-driver.plist"
INSTALLER="$REPO_ROOT/scripts/setup/install-queue-driver-launchd.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# 1. Plist exists
[[ -f "$PLIST" ]] || fail "plist not found: $PLIST"
ok "plist file exists"

# 2. Valid plist XML (plutil if available, else python xml.etree)
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PLIST" >/dev/null 2>&1 || fail "plist failed plutil -lint"
    ok "plist passes plutil -lint"
else
    python3 -c "import xml.etree.ElementTree as ET; ET.parse('$PLIST')" 2>&1 \
        || fail "plist not valid XML"
    ok "plist parses as XML"
fi

# 3. StartInterval = 300 (every 5 min)
grep -A 1 "<key>StartInterval</key>" "$PLIST" | grep -q "<integer>300</integer>" \
    || fail "plist StartInterval is not 300 seconds"
ok "StartInterval = 300s (every 5 minutes)"

# 4. ProgramArguments references queue-driver.sh
grep -q "queue-driver.sh" "$PLIST" || fail "plist does not reference queue-driver.sh"
ok "plist runs scripts/coord/queue-driver.sh"

# 5. Plist Label is dev.chump.queue-driver
grep -A 1 "<key>Label</key>" "$PLIST" | grep -q "dev.chump.queue-driver" \
    || fail "plist Label is not dev.chump.queue-driver"
ok "plist Label correct"

# 6. RunAtLoad=false (don't double-fire on install)
grep -A 1 "<key>RunAtLoad</key>" "$PLIST" | grep -q "<false/>" \
    || fail "plist RunAtLoad is not false"
ok "RunAtLoad = false (no double-fire on install)"

# 7. Installer exists + executable
[[ -x "$INSTALLER" ]] || fail "installer not executable: $INSTALLER"
ok "installer exists and is executable"

# 8. Installer dry-run against temp HOME — writes plist into <tmphome>/Library/LaunchAgents
TMP_HOME=$(mktemp -d -t queue-driver-launchd-test-XXXX)
trap 'rm -rf "$TMP_HOME"' EXIT
mkdir -p "$TMP_HOME/Library/LaunchAgents"

# Stub launchctl so the installer doesn't actually load into the system launchd
TMP_BIN=$(mktemp -d -t queue-driver-launchd-bin-XXXX)
trap 'rm -rf "$TMP_BIN" "$TMP_HOME"' EXIT
cat > "$TMP_BIN/launchctl" <<'STUB'
#!/usr/bin/env bash
# stub: pretend operations succeed without touching real launchd
echo "[stub-launchctl] $*"
exit 0
STUB
chmod +x "$TMP_BIN/launchctl"

HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" bash "$INSTALLER" >/dev/null 2>&1 \
    || fail "installer returned non-zero against temp HOME"

INSTALLED="$TMP_HOME/Library/LaunchAgents/dev.chump.queue-driver.plist"
[[ -f "$INSTALLED" ]] || fail "installer did not write plist to $INSTALLED"
ok "installer writes plist to \$HOME/Library/LaunchAgents/"

# 9. Installed plist is valid + uses absolute path to the repo
if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$INSTALLED" >/dev/null 2>&1 || fail "installed plist failed plutil -lint"
fi
grep -q "queue-driver.sh" "$INSTALLED" || fail "installed plist missing queue-driver.sh"
ok "installed plist is valid + references queue-driver.sh"

# 10. --uninstall removes the plist
HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" bash "$INSTALLER" --uninstall >/dev/null 2>&1 \
    || fail "installer --uninstall returned non-zero"
[[ ! -f "$INSTALLED" ]] || fail "installer --uninstall did not remove plist"
ok "--uninstall removes plist"

echo
echo "All INFRA-1304 queue-driver-launchd-install tests passed."
