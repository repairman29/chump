#!/usr/bin/env bash
# scripts/setup/install-cluster-detector-launchd.sh — INFRA-1987 (THE FLOOR Phase 1)
#
# Installs the cluster-detector launchd job (2-minute cadence, cron-style).
# Pairs with INFRA-1987 (cluster-detector.sh) — sharper signal than W-AGG.
#
# Idempotent: unload + reload if already installed.

set -euo pipefail

# INFRA-2365: resolve to the MAIN worktree, not whatever worktree this
# installer runs from (see scripts/lib/resolve-main-worktree.sh; INFRA-451
# class — a baked-in linked/temp worktree path dies with exit=78 once the
# worktree is reaped).
# shellcheck source=../lib/resolve-main-worktree.sh
source "$(cd "$(dirname "$0")" && pwd)/../lib/resolve-main-worktree.sh"
REPO_ROOT="$(resolve_main_worktree "$0")" || {
    echo "FAIL: could not resolve main worktree from $0" >&2
    exit 1
}
SCRIPT="$REPO_ROOT/scripts/coord/cluster-detector.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.chump.cluster-detector.plist"

[[ -x "$SCRIPT" ]] || { echo "missing/non-executable: $SCRIPT"; exit 1; }

mkdir -p "$PLIST_DIR"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.chump.cluster-detector</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>StartInterval</key>
    <integer>120</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${REPO_ROOT}/.chump-locks/cluster-detector.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ROOT}/.chump-locks/cluster-detector.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:${HOME}/.cargo/bin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

# Unload if previously loaded (idempotent reinstall)
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"

echo "[install-cluster-detector] installed launchd at $PLIST (2min cadence)"
echo "[install-cluster-detector] inspect: launchctl print gui/$(id -u)/com.chump.cluster-detector"
echo "[install-cluster-detector] logs:    tail -f ${REPO_ROOT}/.chump-locks/cluster-detector.log"
