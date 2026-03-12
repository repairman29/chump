#!/usr/bin/env bash
# scripts/adb-pair.sh — One-time wireless ADB pairing with a Pixel phone.
#
# Usage:
#   ./scripts/adb-pair.sh <ip:pairing_port> <pairing_code>
#
# Steps before running:
#   1. On your Pixel: Settings → Developer options → Wireless debugging → ON
#   2. Tap "Pair device with pairing code"
#   3. Note the IP address, pairing port, and 6-digit code shown
#   4. Run this script with those values
#   5. After pairing, note the IP:port on the Wireless debugging screen (NOT the pairing port)
#   6. Add to .env: CHUMP_ADB_DEVICE=<ip>:<port>
#
# Prerequisites:
#   - adb installed (brew install android-platform-tools on macOS)
#   - Phone and Mac on the same Wi-Fi network

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if ! command -v adb &>/dev/null; then
    echo -e "${RED}Error: adb not found.${NC}"
    echo "Install with: brew install android-platform-tools"
    exit 1
fi

if [ $# -lt 2 ]; then
    echo -e "${YELLOW}Usage: $0 <ip:pairing_port> <pairing_code>${NC}"
    echo ""
    echo "Example: $0 192.168.1.42:37123 482916"
    echo ""
    echo "Get these from your Pixel:"
    echo "  Settings → Developer options → Wireless debugging → Pair device with pairing code"
    exit 1
fi

PAIR_ADDR="$1"
PAIR_CODE="$2"

echo -e "${YELLOW}Pairing with device at ${PAIR_ADDR}...${NC}"
echo ""

# Kill any existing ADB server to avoid stale state
adb kill-server 2>/dev/null || true
sleep 1
adb start-server

# Pair
if adb pair "${PAIR_ADDR}" "${PAIR_CODE}"; then
    echo ""
    echo -e "${GREEN}Pairing successful!${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Look at your phone's Wireless debugging screen"
    echo "2. Note the IP address and port shown (NOT the pairing port)"
    echo "   It will look like: 192.168.1.42:5555 or similar"
    echo "3. Add to your .env file:"
    echo ""
    echo "   CHUMP_ADB_ENABLED=1"
    echo "   CHUMP_ADB_DEVICE=<ip>:<port>"
    echo ""
    echo "4. Test connection:"
    echo "   adb connect <ip>:<port>"
    echo "   adb devices"
    echo ""

    # Try to auto-detect the connect port from adb devices
    echo -e "${YELLOW}Checking for connected devices...${NC}"
    adb devices -l
    echo ""

    # Prompt for connect address
    read -rp "Enter the IP:port from Wireless debugging screen (or press Enter to skip): " CONNECT_ADDR

    if [ -n "${CONNECT_ADDR}" ]; then
        echo -e "${YELLOW}Connecting to ${CONNECT_ADDR}...${NC}"
        if adb connect "${CONNECT_ADDR}"; then
            echo ""
            echo -e "${GREEN}Connected!${NC}"
            adb devices -l
            echo ""

            # Offer to add to .env
            ENV_FILE=".env"
            if [ -f "${ENV_FILE}" ]; then
                echo -e "${YELLOW}Found ${ENV_FILE}. Checking for existing ADB config...${NC}"
                if grep -q "CHUMP_ADB_DEVICE" "${ENV_FILE}"; then
                    echo "CHUMP_ADB_DEVICE already in .env — update it manually if the address changed."
                else
                    read -rp "Add CHUMP_ADB_ENABLED=1 and CHUMP_ADB_DEVICE=${CONNECT_ADDR} to .env? [y/N] " yn
                    if [[ "${yn}" =~ ^[Yy] ]]; then
                        echo "" >> "${ENV_FILE}"
                        echo "# ADB phone control (added by adb-pair.sh)" >> "${ENV_FILE}"
                        echo "CHUMP_ADB_ENABLED=1" >> "${ENV_FILE}"
                        echo "CHUMP_ADB_DEVICE=${CONNECT_ADDR}" >> "${ENV_FILE}"
                        echo -e "${GREEN}Added to .env.${NC}"
                    fi
                fi
            else
                echo "No .env found in current directory. Add manually:"
                echo "  CHUMP_ADB_ENABLED=1"
                echo "  CHUMP_ADB_DEVICE=${CONNECT_ADDR}"
            fi

            echo ""
            echo -e "${GREEN}Setup complete. Chump can now control your phone.${NC}"
            echo "Quick test: adb -s ${CONNECT_ADDR} shell dumpsys battery"
        else
            echo -e "${RED}Connection failed. Check the IP:port and that your phone's screen is unlocked.${NC}"
            exit 1
        fi
    fi
else
    echo ""
    echo -e "${RED}Pairing failed.${NC}"
    echo "Check that:"
    echo "  - The pairing code hasn't expired (they timeout quickly)"
    echo "  - Your Mac and phone are on the same Wi-Fi network"
    echo "  - The IP:port is the PAIRING port (shown in the pairing dialog)"
    exit 1
fi
