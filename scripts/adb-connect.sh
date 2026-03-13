#!/usr/bin/env bash
# scripts/adb-connect.sh — Connect to wireless ADB device (e.g. after reboot).
#
# Usage:
#   ./scripts/adb-connect.sh              # use CHUMP_ADB_DEVICE from .env
#   ./scripts/adb-connect.sh 10.1.10.9:34085   # connect to this address
#
# Use Wireless debugging (Developer options), not adb tcpip 5555, so the phone
# stays connectable over Wi-Fi after every reboot. If the port changed, get
# the new IP:port from Settings → Developer options → Wireless debugging.

set -euo pipefail

if ! command -v adb &>/dev/null; then
    echo "Error: adb not found. Install with: brew install android-platform-tools"
    exit 1
fi

ADDR="${1:-}"
if [ -z "${ADDR}" ]; then
    if [ -f .env ]; then
        ADDR=$(grep -E '^CHUMP_ADB_DEVICE=' .env | cut -d= -f2- | tr -d '"'\''')
    fi
fi
if [ -z "${ADDR}" ]; then
    echo "Usage: $0 [ip:port]"
    echo "  With no arg, uses CHUMP_ADB_DEVICE from .env"
    echo "  Example: $0 10.1.10.9:34085"
    exit 1
fi

adb connect "${ADDR}"
adb devices -l
