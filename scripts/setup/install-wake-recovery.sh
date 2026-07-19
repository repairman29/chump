#!/usr/bin/env bash
# install-wake-recovery.sh — RESILIENT-169: build + register the chumpwake
# wake-listener daemon (com.chump.wake-recovery).
#
#   install-wake-recovery.sh              build, install, load
#   install-wake-recovery.sh --uninstall  bootout + remove plist
#
# Verify: launchctl print "gui/$(id -u)/com.chump.wake-recovery"
# Logs  : /tmp/chump-wake-recovery.log
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# RESILIENT-168: never bake a temp-clone path into a persistent plist.
case "$REPO_ROOT" in
    /tmp/*|/private/tmp/*|/var/folders/*)
        if [[ "${CHUMP_INSTALL_ALLOW_TMP:-0}" != "1" ]]; then
            echo "ERROR: refusing to install a persistent daemon from temp path $REPO_ROOT" >&2
            echo "  (run from the canonical checkout, or CHUMP_INSTALL_ALLOW_TMP=1 to override)" >&2
            exit 1
        fi
        ;;
esac

LABEL="com.chump.wake-recovery"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN="$HOME/.local/bin/chumpwake"
SRC="$REPO_ROOT/tools/chumpwake/main.swift"
UID_N="$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "gui/${UID_N}/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "[install-wake-recovery] uninstalled."
    exit 0
fi

echo "[install-wake-recovery] building chumpwake..."
mkdir -p "$(dirname "$BIN")"
xcrun swiftc -O -o "$BIN" "$SRC"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>${BIN}</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CHUMP_WAKE_RECOVERY_SH</key>
        <string>${REPO_ROOT}/scripts/ops/wake-recovery.sh</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/chump-wake-recovery.log</string>
    <key>StandardErrorPath</key><string>/tmp/chump-wake-recovery.log</string>
</dict>
</plist>
PLIST

# RESILIENT-168 lessons: bootout stale copy, clear disabled-override, load.
launchctl bootout "gui/${UID_N}/${LABEL}" 2>/dev/null || true
launchctl enable "gui/${UID_N}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_N}" "$PLIST_PATH"

echo "[install-wake-recovery] loaded. Verify: launchctl print gui/${UID_N}/${LABEL} | grep state"
echo "[install-wake-recovery] wake test: close the lid 30s (on power), reopen, then:"
echo "  grep wake_recovery ${REPO_ROOT}/.chump-locks/ambient.jsonl | tail -1"
