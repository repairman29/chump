#!/usr/bin/env bash
# Run Playwright PWA tests against chump --web (expects a reachable model server — Ollama on 11434 by default).
# Resolves the Chump web base URL: CHUMP_E2E_BASE_URL / CHUMP_E2E_PORT, then logs/chump-web-bound-port,
# then probes CHUMP_WEB_PORT, 3847, 3000, 3848 for chump-web health (same order as scripts/lib/chump-web-base.sh).
# Usage: from repo root, after `cargo build --bin chump`:
#   ./scripts/run-ui-e2e.sh
# Env:
#   CHUMP_E2E_BASE_URL   full URL (if set, used as-is)
#   CHUMP_E2E_PORT       force port when BASE_URL unset
#   CHUMP_WEB_PORT       from .env — probed early; also default when starting a new server if nothing listens
#   CHUMP_REPO / CHUMP_HOME  repo root for logs/chump-web-bound-port (defaults to this repo)
#   CHUMP_E2E_SKIP_SERVER if 1, do not start chump (expect server already up at resolved URL)
#   OPENAI_API_BASE       default http://127.0.0.1:11434/v1
#   OPENAI_MODEL          default qwen2.5:14b (match your `ollama pull`)
#   CHUMP_E2E_FAST        if 1, short Playwright timeouts (iterate on UI without waiting on LLM)
#   CHUMP_E2E_LLM         if 1, Playwright runs daily-driver-llm.spec.ts (real model); default off so CI stays fast
#   CHUMP_E2E_VERIFY_TOOL_POLICY  if 1, curl /api/stack-status and require JSON tool_policy (preflight hook)
#   PW_WORKERS            Playwright worker count (default 1 for local Ollama)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi

# shellcheck source=scripts/lib/chump-web-base.sh
source "$ROOT/scripts/lib/chump-web-base.sh"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
export CHUMP_E2E_BASE_URL="$(chump_resolve_e2e_base_url)"
PORT="$(chump_port_from_base_url "$CHUMP_E2E_BASE_URL")"
echo "Chump web target: ${CHUMP_E2E_BASE_URL} (port ${PORT})"

export OPENAI_API_BASE="${OPENAI_API_BASE:-http://127.0.0.1:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"

echo "Building target/debug/chump (ensures API routes match this tree)…"
cargo build --bin chump

_models_url="${OPENAI_API_BASE%/v1}/v1/models"
if [[ "$OPENAI_API_BASE" == *"127.0.0.1:11434"* || "$OPENAI_API_BASE" == *"localhost:11434"* ]]; then
  echo "Waiting for Ollama at ${_models_url} (up to ~4 min)…"
  ok=0
  for _ in $(seq 1 120); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$_models_url" 2>/dev/null || echo 000)
    if [[ "$code" == "200" ]]; then
      ok=1
      break
    fi
    sleep 2
  done
  if [[ "$ok" != "1" ]]; then
    echo "FAIL: Ollama not reachable (HTTP ${_models_url} -> ${code:-000})" >&2
    echo "Start: ollama serve && ollama pull ${OPENAI_MODEL}" >&2
    exit 1
  fi
  echo "Ollama OK (OPENAI_MODEL=${OPENAI_MODEL})"
else
  echo "Non-local OPENAI_API_BASE; skipping Ollama wait (set to 127.0.0.1:11434/v1 for local golden path)"
fi

cleanup() {
  if [[ -n "${CHUMP_E2E_PID:-}" ]] && kill -0 "${CHUMP_E2E_PID}" 2>/dev/null; then
    kill "${CHUMP_E2E_PID}" 2>/dev/null || true
    wait "${CHUMP_E2E_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "${CHUMP_E2E_SKIP_SERVER:-0}" != "1" ]]; then
  if chump_web_health_ok "$CHUMP_E2E_BASE_URL"; then
    echo "Using existing Chump web at ${CHUMP_E2E_BASE_URL}"
  else
    echo "Starting chump --web on port ${PORT} (CHUMP_WEB_TOKEN cleared; inference: ${OPENAI_MODEL})…"
    env CHUMP_WEB_PORT="${PORT}" CHUMP_WEB_TOKEN="" \
      OPENAI_API_BASE="$OPENAI_API_BASE" OPENAI_API_KEY="$OPENAI_API_KEY" OPENAI_MODEL="$OPENAI_MODEL" \
      ./target/debug/chump --web &
    CHUMP_E2E_PID=$!
    H="${CHUMP_WEB_HOST:-127.0.0.1}"
    MARKER_ROOT="${CHUMP_REPO:-$ROOT}"
    for _ in $(seq 1 90); do
      if [[ -f "${MARKER_ROOT}/logs/chump-web-bound-port" ]]; then
        bp=""
        IFS= read -r bp <"${MARKER_ROOT}/logs/chump-web-bound-port" || true
        bp="${bp//$'\r'/}"
        bp="${bp//$'\n'/}"
        if [[ "$bp" =~ ^[0-9]+$ ]]; then
          export CHUMP_E2E_BASE_URL="http://${H}:${bp}"
          PORT="$bp"
        fi
      fi
      if chump_web_health_ok "$CHUMP_E2E_BASE_URL"; then
        break
      fi
      sleep 1
    done
    if ! chump_web_health_ok "$CHUMP_E2E_BASE_URL"; then
      echo "Timed out waiting for Chump web (chump-web health); last tried ${CHUMP_E2E_BASE_URL}" >&2
      exit 1
    fi
    echo "Chump web ready at ${CHUMP_E2E_BASE_URL}"
  fi
fi

if [[ "${CHUMP_E2E_VERIFY_TOOL_POLICY:-0}" == "1" ]]; then
  echo "CHUMP_E2E_VERIFY_TOOL_POLICY=1: checking GET /api/stack-status includes tool_policy…"
  _ss="$(curl -sS --max-time 15 "${CHUMP_E2E_BASE_URL%/}/api/stack-status" || true)"
  if [[ "$_ss" != *'"tool_policy"'* ]]; then
    echo "FAIL: /api/stack-status response missing tool_policy (is chump --web running?)" >&2
    exit 1
  fi
  echo "stack-status tool_policy: OK"
fi

cd e2e
if [[ ! -d node_modules ]]; then
  npm install
fi
npx playwright install chromium
npx playwright test "$@"
