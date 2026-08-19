#!/usr/bin/env bash
# scripts/setup/install-checkout-sync-drift-watchdog-launchd.sh — RESILIENT-149
#
# Install the com.chump.checkout-sync-drift-watchdog LaunchAgent that runs
# scripts/coord/checkout-sync-drift-watchdog.sh on a cadence (default 600s =
# 10 min). This is the alarm on top of MISSION-027's checkout-sync daemon —
# if that daemon stalls or its plist unloads, the running checkout can drift
# silently behind origin/main with no signal. This watchdog catches that and
# self-heals.
#
# Usage:
#   bash scripts/setup/install-checkout-sync-drift-watchdog-launchd.sh            # install + load
#   bash scripts/setup/install-checkout-sync-drift-watchdog-launchd.sh --check    # exits 0 if loaded
#   bash scripts/setup/install-checkout-sync-drift-watchdog-launchd.sh --uninstall
#
# Override interval for testing (seconds):
#   CHUMP_CHECKOUT_DRIFT_WATCHDOG_INTERVAL=60 bash scripts/setup/install-checkout-sync-drift-watchdog-launchd.sh
#
# Point at a dedicated fleet checkout instead of this repo root:
#   CHUMP_SYNC_TARGET_DIR=/path/to/fleet/checkout bash scripts/setup/install-checkout-sync-drift-watchdog-launchd.sh

set -euo pipefail

case "$(uname -s)" in
  Darwin) ;;
  *) echo "skip: not macOS"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# INFRA-2365: resolve to the MAIN worktree, not whatever worktree this
# installer runs from (see scripts/lib/resolve-main-worktree.sh; INFRA-451
# class — a baked-in linked/temp worktree path dies with exit=78 once the
# worktree is reaped).
# shellcheck source=../lib/resolve-main-worktree.sh
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO_ROOT="$(resolve_main_worktree "${BASH_SOURCE[0]}")" || {
    echo "FAIL: could not resolve main worktree from ${BASH_SOURCE[0]}" >&2
    exit 1
}
PLIST_NAME="com.chump.checkout-sync-drift-watchdog"
DEST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
INTERVAL="${CHUMP_CHECKOUT_DRIFT_WATCHDOG_INTERVAL:-600}"
TARGET_DIR="${CHUMP_SYNC_TARGET_DIR:-$REPO_ROOT}"

WATCHDOG_SCRIPT="$REPO_ROOT/scripts/coord/checkout-sync-drift-watchdog.sh"

# ── --check mode ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    if launchctl list 2>/dev/null | grep -q "$PLIST_NAME"; then
        echo "ok: $PLIST_NAME is loaded"
        exit 0
    else
        echo "MISSING: $PLIST_NAME not loaded"
        exit 1
    fi
fi

# ── --uninstall mode ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -f "$DEST" ]]; then
        launchctl unload "$DEST" 2>/dev/null || true
        rm -f "$DEST"
        echo "uninstalled $PLIST_NAME"
    else
        echo "$PLIST_NAME not installed"
    fi
    exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────
if [[ ! -x "$WATCHDOG_SCRIPT" ]]; then
    echo "ERROR: $WATCHDOG_SCRIPT not found or not executable" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

CARGO_BIN="$HOME/.cargo/bin"
PATH_VALUE="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:${CARGO_BIN}:/usr/bin:/bin"

cat > "$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_NAME}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WATCHDOG_SCRIPT}</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${TARGET_DIR}</string>

  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>/tmp/chump-checkout-sync-drift-watchdog.out.log</string>

  <key>StandardErrorPath</key>
  <string>/tmp/chump-checkout-sync-drift-watchdog.err.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
    <key>CHUMP_SYNC_TARGET_DIR</key>
    <string>${TARGET_DIR}</string>
  </dict>

  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

# Reload idempotently: bootout (ignore error if not loaded) + bootstrap.
launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  watchdog script : ${WATCHDOG_SCRIPT}"
echo "  target dir      : ${TARGET_DIR}"
echo "  interval        : ${INTERVAL}s (~$(( INTERVAL / 60 )) min)"
echo "  verify          : launchctl list | grep checkout-sync-drift-watchdog"
echo "  on-demand       : launchctl start ${PLIST_NAME}"
