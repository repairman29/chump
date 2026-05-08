#!/usr/bin/env bash
# INFRA-681: test FTUE / e2e-pwa workflows skip cleanly when Ollama is unreachable.
# Verifies acceptance criteria: either start ollama before model calls, OR skip with
# clear notice — never block on 120s playwright timeout.
#
# Usage: bash scripts/ci/test-ftue-ollama-gate.sh
# Exit: 0 if tests skip cleanly; 1 if timeout or unexpected failure
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "=== INFRA-681: e2e-pwa Ollama Gate Test ==="
echo "1. Stopping Ollama (if running) to simulate unreachable model..."

# Stop Ollama via brew services or kill any ollama process
if command -v ollama >/dev/null 2>&1; then
  brew services stop ollama 2>/dev/null || true
  killall -9 ollama 2>/dev/null || true
fi

# Verify Ollama is not reachable
echo "2. Verifying Ollama is not reachable..."
if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "ERROR: Ollama is still reachable on 11434" >&2
  exit 1
fi
echo "   ✓ Ollama confirmed unreachable"

# Run e2e tests with strict timeout — Playwright's own timeout is the safety net
echo "3. Running e2e tests with Ollama down (30s strict timeout for the entire run)..."
export CHUMP_E2E_SKIP_SERVER=1  # Don't start chump, assume it's already running
export CHUMP_E2E_FAST=1         # Short Playwright timeouts (60s per test, 15s per expect)

# Subshell with strict timeout: if tests hang beyond 30s, exit with error
timeout 30 npx playwright test e2e/tests/api-and-pwa.spec.ts \
  --grep "Chat /task path" \
  --reporter=list 2>&1 | tee /tmp/ollama-gate-test.log || {
  EXIT_CODE=$?
  if [[ $EXIT_CODE -eq 124 ]]; then
    # Timeout from `timeout` command = tests hung (bad)
    echo "ERROR: Tests timed out (124) — tests did not skip gracefully" >&2
    tail -20 /tmp/ollama-gate-test.log
    exit 1
  else
    # Some other failure — log it
    echo "Tests exited with code $EXIT_CODE" >&2
    tail -20 /tmp/ollama-gate-test.log
    exit $EXIT_CODE
  fi
}

# Check logs for success: expect "SKIPPED" or "[FTUE Ollama Gate]" marker
echo "4. Checking test output for graceful skip markers..."
if grep -q "skipped\|SKIPPED\|FTUE Ollama Gate" /tmp/ollama-gate-test.log; then
  echo "   ✓ Tests skipped cleanly"
  grep -E "skipped|SKIPPED|FTUE Ollama Gate" /tmp/ollama-gate-test.log | head -3
else
  echo "ERROR: Tests did not skip — output below:" >&2
  cat /tmp/ollama-gate-test.log >&2
  exit 1
fi

echo ""
echo "=== FTUE Ollama Gate: PASS ==="
echo "Acceptance criteria met: e2e-pwa tests skip with clear notice when Ollama unreachable."
exit 0
