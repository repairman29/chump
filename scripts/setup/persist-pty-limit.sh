#!/usr/bin/env bash
# scripts/setup/persist-pty-limit.sh — RESILIENT-092
#
# One-time operator script: raises the machine's pty ceiling and persists
# the raise across reboot. This is the "headroom" half of RESILIENT-092 —
# infra-watcher's check-ptys subcommand can detect pressure early, but a
# 511-pty ceiling (macOS default, kern.tty.ptmx_max) still leaves almost no
# slack under a leak. Raising to >=4096 buys real time between "pressure
# detected" and "forkpty actually fails".
#
# macOS: kern.tty.ptmx_max is NOT read from /etc/sysctl.conf on modern macOS
# (that mechanism was removed) — the only reliable persistence path is a
# root LaunchDaemon with RunAtLoad that re-applies `sysctl -w` on every boot.
#
# Linux: kernel.pty.max is a standard sysctl; /etc/sysctl.d/ persists it
# through the normal sysctl.service reload path.
#
# Usage:
#   sudo bash scripts/setup/persist-pty-limit.sh [LIMIT]     # default LIMIT=4096
#
# Verify:
#   macOS:  sysctl -n kern.tty.ptmx_max
#   Linux:  sysctl -n kernel.pty.max
#
# Idempotent — safe to re-run.

set -euo pipefail

LIMIT="${1:-4096}"

if [[ "$LIMIT" -lt 4096 ]]; then
    echo "[persist-pty-limit] WARNING: requested limit ${LIMIT} < 4096 headroom recommended by RESILIENT-092" >&2
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "[persist-pty-limit] must run as root (sudo) — pty ceiling is a kernel-wide setting" >&2
    exit 1
fi

OS="$(uname -s)"

if [[ "$OS" == "Darwin" ]]; then
    echo "[persist-pty-limit] macOS: applying kern.tty.ptmx_max=${LIMIT} now"
    sysctl -w "kern.tty.ptmx_max=${LIMIT}"

    PLIST_PATH="/Library/LaunchDaemons/com.chump.pty-limit.plist"
    cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.chump.pty-limit</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/sbin/sysctl</string>
    <string>-w</string>
    <string>kern.tty.ptmx_max=${LIMIT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/chump-pty-limit.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-pty-limit.err.log</string>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST_PATH"
    chmod 644 "$PLIST_PATH"
    launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
    launchctl bootstrap system "$PLIST_PATH"
    echo "[persist-pty-limit] installed ${PLIST_PATH} — kern.tty.ptmx_max=${LIMIT} will be reapplied on every boot"

elif [[ "$OS" == "Linux" ]]; then
    echo "[persist-pty-limit] Linux: applying kernel.pty.max=${LIMIT} now"
    sysctl -w "kernel.pty.max=${LIMIT}"

    CONF_PATH="/etc/sysctl.d/99-chump-pty-limit.conf"
    printf 'kernel.pty.max = %s\n' "$LIMIT" > "$CONF_PATH"
    echo "[persist-pty-limit] wrote ${CONF_PATH} — kernel.pty.max=${LIMIT} persists via sysctl.d on every boot"

else
    echo "[persist-pty-limit] unsupported platform: ${OS} — no persistence mechanism known" >&2
    exit 1
fi

echo "[persist-pty-limit] done"
