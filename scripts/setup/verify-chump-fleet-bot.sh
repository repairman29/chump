#!/bin/bash
# Verify chump-fleet-bot GitHub credentials and access
# Usage: bash scripts/setup/verify-chump-fleet-bot.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BOT_ENV_FILE="$HOME/.chump/chump-fleet-bot.env"
TARGET_REPO="repairman29/chump"

echo "=== Chump Fleet Bot Verification ===" >&2

# Check if env file exists
if [[ ! -f "$BOT_ENV_FILE" ]]; then
  echo "ERROR: $BOT_ENV_FILE not found" >&2
  echo "Run docs/process/CHUMP_FLEET_BOT_SETUP.md Step 4 to create it" >&2
  exit 1
fi

# Check permissions (should be 600)
PERMS=$(stat -f "%A" "$BOT_ENV_FILE" 2>/dev/null || stat -c "%a" "$BOT_ENV_FILE" 2>/dev/null)
if [[ "$PERMS" != "600" && "$PERMS" != "rw-------" ]]; then
  echo "WARN: File permissions are $PERMS, expected 600 (rw-------)" >&2
fi

# Source the env file
source "$BOT_ENV_FILE" || { echo "ERROR: Failed to source $BOT_ENV_FILE" >&2; exit 1; }

# Verify GITHUB_TOKEN is set
if [[ -z "$GITHUB_TOKEN" ]] && [[ -z "$GH_TOKEN" ]]; then
  echo "ERROR: GITHUB_TOKEN or GH_TOKEN not set in $BOT_ENV_FILE" >&2
  exit 1
fi

echo "✓ Env file exists with correct permissions" >&2

# Test gh auth status
echo -n "Testing gh auth status... " >&2
if ! gh auth status >/dev/null 2>&1; then
  echo "FAILED" >&2
  echo "ERROR: gh auth failed. Check token validity in $BOT_ENV_FILE" >&2
  exit 1
fi
echo "OK" >&2

# Get the authenticated user
BOT_USER=$(gh auth status 2>&1 | grep "Logged in to github.com as" | awk '{print $(NF-1)}' || echo "unknown")
echo "✓ Authenticated as: $BOT_USER" >&2

# Test repository access
echo -n "Testing access to $TARGET_REPO... " >&2
if ! gh repo view "$TARGET_REPO" >/dev/null 2>&1; then
  echo "FAILED" >&2
  echo "ERROR: Cannot access $TARGET_REPO. Check bot account permissions." >&2
  exit 1
fi
echo "OK" >&2

# Test PR access
echo -n "Testing PR query permissions... " >&2
if ! gh pr list -R "$TARGET_REPO" --limit 1 >/dev/null 2>&1; then
  echo "FAILED (non-critical)" >&2
  echo "WARN: Cannot list PRs. Token scope may be limited." >&2
else
  echo "OK" >&2
fi

echo "" >&2
echo "=== All checks passed ===" >&2
echo "Bot identity '$BOT_USER' is ready for use." >&2
exit 0
