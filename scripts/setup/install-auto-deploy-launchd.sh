#!/usr/bin/env bash
# scripts/setup/install-auto-deploy-launchd.sh — MISSION-012
#
# Install the com.chump.auto-deploy LaunchAgent that runs
# scripts/ops/auto-deploy.sh every 1200s (~20 min).
#
# auto-deploy.sh delegates all building to refresh-runner-binary.sh which
# uses an isolated detached worktree — the main checkout is NEVER touched.
#
# Usage:
#   bash scripts/setup/install-auto-deploy-launchd.sh            # install + load
#   bash scripts/setup/install-auto-deploy-launchd.sh --check    # exits 0 if loaded
#   bash scripts/setup/install-auto-deploy-launchd.sh --uninstall
#
# Override interval for testing (seconds):
#   CHUMP_AUTO_DEPLOY_INTERVAL=300 bash scripts/setup/install-auto-deploy-launchd.sh

set -euo pipefail

case "$(uname -s)" in
  Darwin) ;;
  *) echo "skip: not macOS"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_NAME="com.chump.auto-deploy"
DEST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
INTERVAL="${CHUMP_AUTO_DEPLOY_INTERVAL:-1200}"

DEPLOY_SCRIPT="$REPO_ROOT/scripts/ops/auto-deploy.sh"

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
if [[ ! -x "$DEPLOY_SCRIPT" ]]; then
    echo "ERROR: $DEPLOY_SCRIPT not found or not executable" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$REPO_ROOT/.chump-locks/auto-deploy-logs"

# PATH must include cargo + brew binaries for git and bash to resolve correctly.
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
    <string>${DEPLOY_SCRIPT}</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${REPO_ROOT}</string>

  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>

  <key>RunAtLoad</key>
  <false/>

  <key>StandardOutPath</key>
  <string>/tmp/chump-auto-deploy.out.log</string>

  <key>StandardErrorPath</key>
  <string>/tmp/chump-auto-deploy.err.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>PATH</key>
    <string>${PATH_VALUE}</string>
    <key>CHUMP_REPO_ROOT</key>
    <string>${REPO_ROOT}</string>
  </dict>

  <key>ThrottleInterval</key>
  <integer>600</integer>
</dict>
</plist>
EOF

# Reload idempotently: bootout (ignore error if not loaded) + bootstrap.
launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "Installed: $DEST"
echo "  deploy script : ${DEPLOY_SCRIPT}"
echo "  interval      : ${INTERVAL}s (~$(( INTERVAL / 60 )) min)"
echo "  verify        : launchctl list | grep auto-deploy"
echo "  on-demand     : launchctl start ${PLIST_NAME}"
echo "  logs          : ${REPO_ROOT}/.chump-locks/auto-deploy-logs/"
