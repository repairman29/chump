#!/usr/bin/env bash
# Real Tauri (Cowork) UI via tauri-driver — Linux only (see e2e-tauri/README.md).
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "run-tauri-e2e.sh: skipping on $(uname -s) — Tauri WebDriver is not available for WKWebView on macOS."
  echo "  • Local browser UI: ./scripts/run-ui-e2e.sh (PWA)"
  echo "  • Cowork shell automation: see GitHub Actions job tauri-cowork-e2e (ubuntu-latest)"
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT="${CHUMP_TAURI_E2E_PORT:-3848}"
export CHUMP_DESKTOP_API_BASE="http://127.0.0.1:${PORT}"
export CHUMP_DESKTOP_AUTO_WEB="${CHUMP_DESKTOP_AUTO_WEB:-0}"

echo "Building chump + chump-desktop…"
cargo build --bin chump
cargo build -p chump-desktop

if [[ ! -x target/debug/chump-desktop ]]; then
  echo "missing target/debug/chump-desktop" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${CHUMP_PID:-}" ]] && kill -0 "${CHUMP_PID}" 2>/dev/null; then
    kill "${CHUMP_PID}" 2>/dev/null || true
    wait "${CHUMP_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! command -v tauri-driver >/dev/null 2>&1; then
  echo "Install tauri-driver: cargo install tauri-driver --locked" >&2
  exit 1
fi

if ! command -v WebKitWebDriver >/dev/null 2>&1; then
  echo "WebKitWebDriver not on PATH (install webkit2gtk-driver on Debian/Ubuntu)." >&2
  exit 1
fi

echo "Starting chump --web on ${PORT}…"
CHUMP_WEB_PORT="${PORT}" CHUMP_WEB_TOKEN="" ./target/debug/chump --web &
CHUMP_PID=$!
for _ in $(seq 1 90); do
  if curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null

cd e2e-tauri
if [[ ! -d node_modules ]]; then
  npm install
fi

echo "Running WebDriver tests under xvfb…"
xvfb-run -a npm test
