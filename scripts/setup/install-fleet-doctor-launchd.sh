#!/usr/bin/env bash
# install-fleet-doctor-launchd.sh — INFRA-603: install launchd agent that
# runs 'chump fleet doctor' every 5 minutes and emits fleet_doctor_report
# to .chump-locks/ambient.jsonl.
#
# Idempotent: safe to re-run.
# Disable:  launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-fleet-doctor.plist
# Manual:   launchctl start ai.openclaw.chump-fleet-doctor
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/resolve-main-worktree.sh"
REPO="$(resolve_main_worktree "$0")"

PLIST_NAME="ai.openclaw.chump-fleet-doctor.plist"
DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

# Resolve chump binary: prefer cargo-installed, fall back to repo target.
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    elif [[ -x "$HOME/.cargo/bin/chump" ]]; then
        CHUMP_BIN="$HOME/.cargo/bin/chump"
    elif [[ -x "$REPO/target/release/chump" ]]; then
        CHUMP_BIN="$REPO/target/release/chump"
    else
        echo "[install-fleet-doctor-launchd] ERROR: cannot locate chump binary" >&2
        exit 1
    fi
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.openclaw.chump-fleet-doctor</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CHUMP_BIN</string>
    <string>fleet</string>
    <string>doctor</string>
  </array>
  <!-- Every 5 minutes (300s). Emits kind=fleet_doctor_report to
       .chump-locks/ambient.jsonl; exit-code 1 signals a FAIL check. -->
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-fleet-doctor.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-fleet-doctor.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:$HOME/.cargo/bin:/usr/bin:/bin</string>
    <key>CHUMP_REPO</key>
    <string>$REPO</string>
  </dict>
</dict>
</plist>
EOF

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "[install-fleet-doctor-launchd] Installed: $DEST"
echo "[install-fleet-doctor-launchd] Schedule:  every 5 min, runs at load"
echo "[install-fleet-doctor-launchd] Binary:    $CHUMP_BIN"
echo "[install-fleet-doctor-launchd] Logs:      /tmp/chump-fleet-doctor.{out,err}.log"
echo "[install-fleet-doctor-launchd] Verify:    launchctl list | grep ai.openclaw.chump-fleet-doctor"
echo "[install-fleet-doctor-launchd] Manual:    launchctl start ai.openclaw.chump-fleet-doctor"
echo "[install-fleet-doctor-launchd] Disable:   launchctl unload $DEST"
