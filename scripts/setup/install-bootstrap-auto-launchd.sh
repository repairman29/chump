#!/usr/bin/env bash
# install-bootstrap-auto-launchd.sh — INFRA-1808
#
# Registers an hourly launchd agent that runs
# `chump-fleet-bootstrap.sh --auto-tick` so the productization layer
# (META-063/064/065 + INFRA-1257/1258 + REQUIRED_DAEMONS) self-heals
# without an operator manually invoking the bootstrap installer.
#
# Root cause this closes: INFRA-1777 (pr-auto-rebase daemon) and INFRA-1779
# (its launchd plist installer) shipped to the repo 2026-05-22 but sat
# un-installed on the host for a full day because nothing ran the
# bootstrap installer automatically — it only ran when curator-opus-shepherd
# happened to invoke it by hand while debugging a stale PR queue.
#
# All installers the bootstrap manifest / REQUIRED_DAEMONS drive are
# idempotent, so running the bootstrap hourly is safe to repeat.
#
# Idempotent: safe to re-run.
# Disable:    launchctl unload ~/Library/LaunchAgents/dev.chump.bootstrap-auto-install.plist
# Manual fire: launchctl start dev.chump.bootstrap-auto-install
set -euo pipefail

# INFRA-451: resolve to the *main* worktree (not the linked worktree this
# install script may be running from), so the plist absolute path survives
# worktree reaping.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"
PLIST_NAME="dev.chump.bootstrap-auto-install.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.chump.bootstrap-auto-install</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd "$REPO" &amp;&amp; bash scripts/setup/chump-fleet-bootstrap.sh --auto-tick</string>
  </array>
  <!-- Hourly (3600s). Every installer the bootstrap drives is idempotent,
       so re-running hourly just re-affirms an already-healthy host and
       heals a drifted one within an hour instead of days. -->
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-bootstrap-auto-install.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-bootstrap-auto-install.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/bin:/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
</dict>
</plist>
EOF

# Reload (unload + load) so the new plist takes effect immediately.
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-bootstrap-auto-launchd] Installed: $DEST"
echo "[install-bootstrap-auto-launchd] Schedule:  every 1 hour (3600s)"
echo "[install-bootstrap-auto-launchd] Logs:      /tmp/chump-bootstrap-auto-install.{out,err}.log"
echo "[install-bootstrap-auto-launchd] Verify:    launchctl list | grep dev.chump.bootstrap-auto-install"
echo "[install-bootstrap-auto-launchd] Manual:    launchctl start dev.chump.bootstrap-auto-install"
echo "[install-bootstrap-auto-launchd] Disable:   launchctl unload $DEST"
