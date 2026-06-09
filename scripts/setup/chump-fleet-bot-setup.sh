#!/usr/bin/env bash
# chump-fleet-bot-setup.sh — META-211
#
# Securely stores the chump-fleet-bot Personal Access Token (PAT) in macOS
# Keychain for access by daemons and coordination scripts.
#
# Usage:
#   bash scripts/setup/chump-fleet-bot-setup.sh
#
# The script will:
#   1. Prompt for the PAT (input hidden)
#   2. Validate token format (ghp_ prefix)
#   3. Store in Keychain under service "chump-fleet-bot-pat"
#   4. Verify retrieval works
#   5. Print diagnostic commands
#
# Manual Keychain entry (if needed):
#   security add-generic-password -s "chump-fleet-bot-pat" -a "ghp" -w "ghp_..." -U
#
# Verify:
#   security find-generic-password -s "chump-fleet-bot-pat" -w

set -euo pipefail

KEYCHAIN_SERVICE="chump-fleet-bot-pat"
KEYCHAIN_ACCOUNT="ghp"

# ANSI color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Chump Fleet Bot PAT Setup ===${NC}"
echo ""
echo "This script securely stores your chump-fleet-bot Personal Access Token"
echo "in macOS Keychain for use by Chump daemons and scripts."
echo ""

# Validate we're on macOS
if ! command -v security &>/dev/null; then
  echo -e "${RED}ERROR: 'security' command not found. This script requires macOS.${NC}" >&2
  exit 1
fi

# Prompt for PAT with hidden input
echo -e "${YELLOW}Step 1: Provide the chump-fleet-bot PAT${NC}"
echo "Paste your GitHub Personal Access Token (ghp_...) and press Enter."
echo "(Input will be hidden)"
echo ""

# Read PAT securely (no echo)
read -rsp "GitHub PAT: " PAT
echo ""

# Validate token format
if [[ ! "$PAT" =~ ^ghp_ ]]; then
  echo -e "${RED}ERROR: Invalid token format. GitHub tokens start with 'ghp_'${NC}" >&2
  exit 1
fi

if [[ ${#PAT} -lt 36 ]]; then
  echo -e "${RED}ERROR: Token seems too short. GitHub tokens are typically 36+ chars.${NC}" >&2
  exit 1
fi

echo -e "${GREEN}✓ Token format looks valid${NC}"
echo ""

# Check if Keychain is locked
echo -e "${YELLOW}Step 2: Checking Keychain access${NC}"
if ! security default-keychain > /dev/null 2>&1; then
  echo -e "${YELLOW}⚠ Keychain may be locked. You may be prompted to unlock it.${NC}"
  echo ""
fi

# Store in Keychain
echo "Storing PAT in Keychain under service: $KEYCHAIN_SERVICE"
if security add-generic-password \
  -s "$KEYCHAIN_SERVICE" \
  -a "$KEYCHAIN_ACCOUNT" \
  -w "$PAT" \
  -U 2>&1; then
  echo -e "${GREEN}✓ PAT stored successfully${NC}"
else
  echo -e "${RED}ERROR: Failed to store PAT in Keychain${NC}" >&2
  exit 1
fi
echo ""

# Verify retrieval
echo -e "${YELLOW}Step 3: Verifying retrieval${NC}"
if retrieved_pat="$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>&1)"; then
  if [[ "$retrieved_pat" == "$PAT" ]]; then
    echo -e "${GREEN}✓ PAT retrieval verified${NC}"
  else
    echo -e "${RED}ERROR: Retrieved PAT doesn't match stored PAT${NC}" >&2
    exit 1
  fi
else
  echo -e "${RED}ERROR: Failed to retrieve PAT from Keychain${NC}" >&2
  exit 1
fi
echo ""

# Print diagnostic commands
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo ""
echo "Diagnostic commands:"
echo ""
echo "  # Verify PAT in Keychain:"
echo "  security find-generic-password -s \"$KEYCHAIN_SERVICE\" -w"
echo ""
echo "  # Test with gh CLI:"
echo "  export GH_TOKEN=\$(security find-generic-password -s \"$KEYCHAIN_SERVICE\" -w)"
echo "  gh auth status"
echo ""
echo "  # Update/rotate PAT (run this script again):"
echo "  bash scripts/setup/chump-fleet-bot-setup.sh"
echo ""
echo "  # Remove from Keychain (if needed):"
echo "  security delete-generic-password -s \"$KEYCHAIN_SERVICE\""
echo ""
echo "  # For troubleshooting, see:"
echo "  open -R docs/process/CHUMP_FLEET_BOT_PROVISIONING.md"
echo ""
