#!/usr/bin/env bash
# Build Chump for aarch64 Android and push to the device via ADB (no SSH).
# Use this for the native "Run Linux terminal on Android" VM; the VM sees
# /mnt/shared which usually maps to the device's Downloads folder.
#
# Usage:
#   ./scripts/setup/deploy-android-adb.sh                    # build + push to default path
#   ./scripts/setup/deploy-android-adb.sh /sdcard/Download/chump   # custom path
#
# Requires: ADB in PATH, device connected (USB or wireless). After push, open
# the Terminal app on the Pixel and run: cd /mnt/shared/chump && ./chump --discord

set -e
SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"
# Ensure build output lands in repo (avoid sandbox/CI cache dir)
export CARGO_TARGET_DIR="$REPO_ROOT/target"

# Default path on device that maps to /mnt/shared in the Linux VM
ADB_DEST="${1:-/sdcard/Download/chump}"
# Use ANDROID_SERIAL or pass as second arg for multiple devices (e.g. 10.1.10.9:43203)
ADB_DEVICE="${ANDROID_SERIAL:-${2:-}}"
ADB_CMD="adb"
[[ -n "$ADB_DEVICE" ]] && ADB_CMD="adb -s $ADB_DEVICE"

echo "=== Chump Android ADB deploy ==="
echo "Building for aarch64-linux-android..."
"$SCRIPT_DIR/build-android.sh"

BINARY="$REPO_ROOT/target/aarch64-linux-android/release/chump"
[[ -f "$BINARY" ]] || BINARY="$REPO_ROOT/target/aarch64-linux-android/release/rust-agent"
if [[ ! -f "$BINARY" ]]; then
  echo "Error: Binary not found at $BINARY"
  exit 1
fi

echo ""
echo "Pushing to device: $ADB_DEST"
$ADB_CMD shell "mkdir -p $ADB_DEST"
$ADB_CMD push "$BINARY" "$ADB_DEST/chump"
if [[ -f "$SCRIPT_DIR/start-companion.sh" ]]; then
  $ADB_CMD push "$SCRIPT_DIR/start-companion.sh" "$ADB_DEST/start-companion.sh"
fi
if [[ -f "$SCRIPT_DIR/setup-and-run-termux.sh" ]]; then
  $ADB_CMD push "$SCRIPT_DIR/setup-and-run-termux.sh" "$ADB_DEST/setup-and-run.sh"
fi
if [[ -f "$SCRIPT_DIR/setup-llama-on-termux.sh" ]]; then
  $ADB_CMD push "$SCRIPT_DIR/setup-llama-on-termux.sh" "$ADB_DEST/setup-llama-on-termux.sh"
fi
if [[ -f "$SCRIPT_DIR/setup-termux-once.sh" ]]; then
  $ADB_CMD push "$SCRIPT_DIR/setup-termux-once.sh" "$ADB_DEST/setup-termux-once.sh"
fi
if [[ -f "$SCRIPT_DIR/apply-mabel-badass-env.sh" ]]; then
  $ADB_CMD push "$SCRIPT_DIR/apply-mabel-badass-env.sh" "$ADB_DEST/apply-mabel-badass-env.sh"
fi
echo ""
echo "Deployed. Next steps (see docs/architecture/ANDROID_COMPANION.md — Get Mabel online):"
echo ""
echo "  Termux (run once in order):"
echo "    0) termux-setup-storage"
echo "       bash ~/storage/downloads/chump/setup-termux-once.sh   # SSH + shaderc, persistent sshd on boot"
echo "    1) bash ~/storage/downloads/chump/setup-and-run.sh   # copy chump + .env to ~/chump"
echo "    2) bash ~/storage/downloads/chump/setup-llama-on-termux.sh   # build llama.cpp + download model (one-time)"
echo "    3) cd ~/chump && ./start-companion.sh   # start Mabel"
echo ""
echo "  Native Linux VM (Terminal app):"
echo "    cd /mnt/shared/chump && chmod +x chump && ./chump --discord"
