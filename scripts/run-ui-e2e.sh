#!/usr/bin/env bash
# Run Playwright PWA tests against chump --web.
# Usage: from repo root, after `cargo build --bin chump`:
#   ./scripts/run-ui-e2e.sh
# Env:
#   CHUMP_E2E_PORT   port (default 3847)
#   CHUMP_E2E_SKIP_SERVER  if 1, do not start chump (expect server already up)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PORT="${CHUMP_E2E_PORT:-3847}"
export CHUMP_E2E_BASE_URL="http://127.0.0.1:${PORT}"

echo "Building target/debug/chump (ensures API routes match this tree)…"
cargo build --bin chump

cleanup() {
  if [[ -n "${CHUMP_E2E_PID:-}" ]] && kill -0 "${CHUMP_E2E_PID}" 2>/dev/null; then
    kill "${CHUMP_E2E_PID}" 2>/dev/null || true
    wait "${CHUMP_E2E_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "${CHUMP_E2E_SKIP_SERVER:-0}" != "1" ]]; then
  if curl -sf "${CHUMP_E2E_BASE_URL}/api/health" >/dev/null 2>&1; then
    echo "Using existing server at ${CHUMP_E2E_BASE_URL}"
  else
    echo "Starting chump --web on port ${PORT} (CHUMP_WEB_TOKEN cleared for open auth)…"
    CHUMP_WEB_PORT="${PORT}" CHUMP_WEB_TOKEN="" ./target/debug/chump --web &
    CHUMP_E2E_PID=$!
    for _ in $(seq 1 90); do
      if curl -sf "${CHUMP_E2E_BASE_URL}/api/health" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    if ! curl -sf "${CHUMP_E2E_BASE_URL}/api/health" >/dev/null 2>&1; then
      echo "Timed out waiting for ${CHUMP_E2E_BASE_URL}/api/health" >&2
      exit 1
    fi
  fi
fi

cd e2e
if [[ ! -d node_modules ]]; then
  npm install
fi
npx playwright install chromium
npx playwright test "$@"
