#!/bin/bash
# Test: subagent shipping epilogue template exists and contains all required sections

set -e

EPILOGUE_FILE="scripts/dispatch/subagent-shipping-epilogue.md"

echo "[test-subagent-shipping-epilogue] Checking $EPILOGUE_FILE exists..."
if [[ ! -f "$EPILOGUE_FILE" ]]; then
  echo "FAIL: $EPILOGUE_FILE not found"
  exit 1
fi

echo "[test-subagent-shipping-epilogue] Verifying required sections..."

# Check for bot-merge.sh canonical path
if ! grep -q "scripts/coord/bot-merge.sh --gap" "$EPILOGUE_FILE"; then
  echo "FAIL: bot-merge.sh canonical path not found"
  exit 1
fi

# Check for chump-doctor heal
if ! grep -q "scripts/dev/chump-doctor.sh" "$EPILOGUE_FILE"; then
  echo "FAIL: chump-doctor.sh heal command not found"
  exit 1
fi

# Check for manual recovery path (git push)
if ! grep -q "git push -u origin.*--force-with-lease" "$EPILOGUE_FILE"; then
  echo "FAIL: manual recovery git push path not found"
  exit 1
fi

# Check for gh pr create
if ! grep -q "gh pr create" "$EPILOGUE_FILE"; then
  echo "FAIL: gh pr create manual recovery not found"
  exit 1
fi

# Check for gh pr merge
if ! grep -q "gh pr merge.*--auto --squash" "$EPILOGUE_FILE"; then
  echo "FAIL: gh pr merge auto-merge not found"
  exit 1
fi

# Check for forbidden anti-patterns section
if ! grep -q "Forbidden" "$EPILOGUE_FILE"; then
  echo "FAIL: forbidden anti-patterns section not found"
  exit 1
fi

# Check for final report format
if ! grep -q "PR number:" "$EPILOGUE_FILE"; then
  echo "FAIL: final report format not found"
  exit 1
fi

# Verify CLAUDE.md references the new file
if ! grep -q "scripts/dispatch/subagent-shipping-epilogue.md" CLAUDE.md; then
  echo "FAIL: CLAUDE.md does not reference scripts/dispatch/subagent-shipping-epilogue.md"
  exit 1
fi

echo "[test-subagent-shipping-epilogue] ✓ All checks passed"
exit 0
