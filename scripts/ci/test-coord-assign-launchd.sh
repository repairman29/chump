#!/usr/bin/env bash
# test-coord-assign-launchd.sh — RESILIENT-271
#
# Verifies the com.chump.coord-assign launchd plist + installer that wires
# the `chump-coord assign` push-routing daemon (FLEET-034 / INFRA-2476) into
# launchd. Before this, the daemon was built code-on-disk but never ran, so
# preferred_machine could never route work via the mesh — this gate proves
# the install path exists and produces a valid, loadable plist:
#   1. Plist template exists and is valid XML.
#   2. Plist has RunAtLoad=true + KeepAlive=true (persistent daemon, not a
#      periodic StartInterval poke — the daemon owns its own poll loop).
#   3. ProgramArguments invokes the `assign` subcommand.
#   4. Installer script exists and is executable.
#   5. Installer install-run against a temp HOME (with stubbed launchctl and
#      a fake chump-coord binary) writes the plist with placeholders resolved.
#   6. Installed plist has no leftover *_PLACEHOLDER tokens.
#   7. --uninstall removes the plist.
#   8. --check exits 1 before install / when not loaded.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$REPO_ROOT/scripts/setup/com.chump.coord-assign.plist"
INSTALLER="$REPO_ROOT/scripts/setup/install-coord-assign-launchd.sh"

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

# 3. RunAtLoad = true, KeepAlive = true (persistent daemon)
grep -A 1 "<key>RunAtLoad</key>" "$PLIST" | grep -q "<true/>" \
    || fail "plist RunAtLoad is not true"
ok "RunAtLoad = true"
grep -A 1 "<key>KeepAlive</key>" "$PLIST" | grep -q "<true/>" \
    || fail "plist KeepAlive is not true"
ok "KeepAlive = true (relaunch on exit — fail-open NATS-down exits get restarted)"

# 4. ProgramArguments invokes the assign subcommand
grep -A 3 "<key>ProgramArguments</key>" "$PLIST" | grep -q "<string>assign</string>" \
    || fail "plist does not invoke the 'assign' subcommand"
ok "plist invokes 'chump-coord assign'"

# 5. Plist Label is com.chump.coord-assign
grep -A 1 "<key>Label</key>" "$PLIST" | grep -q "com.chump.coord-assign" \
    || fail "plist Label is not com.chump.coord-assign"
ok "plist Label correct"

# 6. Installer exists + executable
[[ -x "$INSTALLER" ]] || fail "installer not executable: $INSTALLER"
ok "installer exists and is executable"

# 7. Installer install-run against a temp HOME
TMP_HOME=$(mktemp -d -t coord-assign-launchd-test-XXXX)
TMP_BIN=$(mktemp -d -t coord-assign-launchd-bin-XXXX)
trap 'rm -rf "$TMP_HOME" "$TMP_BIN"' EXIT
mkdir -p "$TMP_HOME/Library/LaunchAgents"

# Stub launchctl so the installer doesn't touch the real launchd.
cat > "$TMP_BIN/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "[stub-launchctl] $*"
if [[ "$1" == "print" ]]; then
    exit 1  # pretend nothing is loaded yet
fi
exit 0
STUB
chmod +x "$TMP_BIN/launchctl"

# Fake chump-coord binary so bin-resolution succeeds without a real build.
FAKE_COORD="$TMP_BIN/chump-coord"
cat > "$FAKE_COORD" <<'STUB'
#!/usr/bin/env bash
echo "fake chump-coord $*"
STUB
chmod +x "$FAKE_COORD"

HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" CHUMP_COORD_BIN="$FAKE_COORD" \
    bash "$INSTALLER" >/tmp/coord-assign-install.log 2>&1 \
    || fail "installer returned non-zero against temp HOME (see /tmp/coord-assign-install.log)"

INSTALLED="$TMP_HOME/Library/LaunchAgents/com.chump.coord-assign.plist"
[[ -f "$INSTALLED" ]] || fail "installer did not write plist to $INSTALLED"
ok "installer writes plist to \$HOME/Library/LaunchAgents/"

# 8. Installed plist has no leftover placeholders and is valid.
if grep -q "_PLACEHOLDER" "$INSTALLED"; then
    fail "installed plist has unresolved placeholders: $(grep '_PLACEHOLDER' "$INSTALLED")"
fi
ok "installed plist has no unresolved placeholders"

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$INSTALLED" >/dev/null 2>&1 || fail "installed plist failed plutil -lint"
fi
grep -q "$FAKE_COORD" "$INSTALLED" || fail "installed plist does not reference the resolved binary"
ok "installed plist references resolved chump-coord binary"

# 9. --status / --check reflect the stub (not loaded, since our stub 'print' exits 1)
HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" bash "$INSTALLER" --check >/tmp/coord-assign-check.log 2>&1
CHECK_RC=$?
[[ "$CHECK_RC" -ne 0 ]] || fail "--check should fail when stub launchctl reports not-loaded"
ok "--check exits non-zero when not loaded"

# 10. --uninstall removes the plist
HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" bash "$INSTALLER" --uninstall >/dev/null 2>&1 \
    || fail "installer --uninstall returned non-zero"
[[ ! -f "$INSTALLED" ]] || fail "installer --uninstall did not remove plist"
ok "--uninstall removes plist"

echo
echo "All RESILIENT-271 coord-assign-launchd tests passed."
