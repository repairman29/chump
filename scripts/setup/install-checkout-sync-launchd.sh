#!/usr/bin/env bash
# scripts/setup/install-checkout-sync-launchd.sh — MISSION-027
#
# Install the com.chump.checkout-sync LaunchAgent that runs
# scripts/ops/checkout-sync.sh on a cadence (default 300s = 5 min).
#
# checkout-sync.sh keeps the RUNNING checkout — the one the fleet's
# scripts/dispatch/_pick_gap.py and daemons actually execute out of — fast
# on origin/main, independent of MISSION-012's binary-only auto-deploy.
#
# Usage:
#   bash scripts/setup/install-checkout-sync-launchd.sh            # install + load
#   bash scripts/setup/install-checkout-sync-launchd.sh --check    # exits 0 if loaded
#   bash scripts/setup/install-checkout-sync-launchd.sh --uninstall
#
# Override interval for testing (seconds):
#   CHUMP_CHECKOUT_SYNC_INTERVAL=60 bash scripts/setup/install-checkout-sync-launchd.sh
#
# Point at a dedicated fleet checkout instead of this repo root:
#   CHUMP_SYNC_TARGET_DIR=/path/to/fleet/checkout bash scripts/setup/install-checkout-sync-launchd.sh

set -euo pipefail

case "$(uname -s)" in
  Darwin) ;;
  *) echo "skip: not macOS"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_NAME="com.chump.checkout-sync"
DEST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
INTERVAL="${CHUMP_CHECKOUT_SYNC_INTERVAL:-300}"
TARGET_DIR="${CHUMP_SYNC_TARGET_DIR:-$REPO_ROOT}"

SYNC_SCRIPT="$REPO_ROOT/scripts/ops/checkout-sync.sh"

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
if [[ ! -x "$SYNC_SCRIPT" ]]; then
    echo "ERROR: $SYNC_SCRIPT not found or not executable" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$TARGET_DIR/.chump-locks/checkout-sync-logs"

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
    <string>${SYNC_SCRIPT}</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${TARGET_DIR}</string>

  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>/tmp/chump-checkout-sync.out.log</string>

  <key>StandardErrorPath</key>
  <string>/tmp/chump-checkout-sync.err.log</string>

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
echo "  sync script : ${SYNC_SCRIPT}"
echo "  target dir  : ${TARGET_DIR}"
echo "  interval    : ${INTERVAL}s (~$(( INTERVAL / 60 )) min)"
echo "  verify      : launchctl list | grep checkout-sync"
echo "  on-demand   : launchctl start ${PLIST_NAME}"
echo "  logs        : ${TARGET_DIR}/.chump-locks/checkout-sync-logs/"
