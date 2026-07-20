#!/usr/bin/env bash
# install-chumpd.sh — MISSION-051: build + register the supervisor daemon.
#
#   install-chumpd.sh              build release, install, load (KeepAlive)
#   install-chumpd.sh --uninstall  bootout + remove plist (workers die with it)
#
# chumpd OWNS the worker pool: on start it kills the tmux fleet + orphan
# worker loops (CHUMPD_TAKEOVER=0 to skip). The fleet-pool-keeper and farmer
# remain as independent backstops — chumpd's workers write the same
# heartbeats, so the keeper stays quiet while chumpd is healthy.
#
# Verify: launchctl print "gui/$(id -u)/com.chump.chumpd" | grep state
# Logs  : /tmp/chumpd.log  ·  status: /tmp/chumpd-status.json
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

LABEL="com.chump.chumpd"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
BIN="$HOME/.cargo/bin/chumpd"
UID_N="$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "gui/${UID_N}/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "[install-chumpd] uninstalled (workers stopped with the supervisor)."
    exit 0
fi

echo "[install-chumpd] building chumpd (release)..."
(cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --release -p chumpd -q)
cp "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/chumpd" "$BIN"

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
        <key>CHUMP_REPO</key><string>${REPO_ROOT}</string>
        <key>PATH</key><string>/opt/homebrew/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/chumpd.log</string>
    <key>StandardErrorPath</key><string>/tmp/chumpd.log</string>
</dict>
</plist>
PLIST

# RESILIENT-168 lessons: bootout stale copy, clear disabled-override, load.
launchctl bootout "gui/${UID_N}/${LABEL}" 2>/dev/null || true
launchctl enable "gui/${UID_N}/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/${UID_N}" "$PLIST_PATH"

echo "[install-chumpd] loaded (KeepAlive). Pool ownership transfers on first tick."
echo "  verify: launchctl print gui/${UID_N}/${LABEL} | grep state"
echo "  status: cat /tmp/chumpd-status.json"
