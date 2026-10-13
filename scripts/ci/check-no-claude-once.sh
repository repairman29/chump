#!/usr/bin/env bash
# Check that no scripts use the deprecated --once flag.
# This gate ensures all scripts use "claude -p" (probe mode) for auth checks
# and synchronous operations instead of --once.
#
# Exit: 0 if no occurrences found, 1 if any found.
#
# See: RESILIENT-1142 (gate), RESILIENT-1140 (run-fleet.sh), RESILIENT-1141 (test-fleet-auth-check.sh)

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

echo "=== Checking for prohibited --once flag ==="
echo ""

# Search for the deprecated flag across all scripts.
# Pattern: "claude --once" (the prohibited form).
# Exclude: .git/, node_modules/, build artifacts, binary files, and this check script itself.
if grep -r "claude --once" scripts/ --include="*.sh" --exclude="check-no-claude-once.sh" 2>/dev/null; then
  echo ""
  echo "ERROR: Found prohibited flag in scripts."
  echo "Use 'claude -p' (probe mode) instead for auth checks and synchronous operations."
  exit 1
else
  echo "No prohibited flags found"
  exit 0
fi
