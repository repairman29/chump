#!/usr/bin/env bash
# Fleet checks for Tauri desktop + MLX (vLLM-MLX) sidecar workflow.
# Usage (repo root):
#   ./scripts/tauri-desktop-mlx-fleet.sh
# Optional:
#   CHUMP_TAURI_FLEET_USE_MAX_M4=1  — source scripts/env-max_m4.sh before live web check (strict 8000 profile).
#   CHUMP_TAURI_FLEET_WEB=1         — after static checks, start chump --web on a high port and verify /api/health.
#   CHUMP_TAURI_FLEET_SKIP_TEST=1   — skip cargo test -p chump-desktop (e.g. after cargo test --workspace).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CHUMP_HOME="${CHUMP_HOME:-$ROOT}"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"

echo "=== Tauri desktop + MLX fleet ==="

if [[ "${CHUMP_TAURI_FLEET_USE_MAX_M4:-}" == "1" ]]; then
  # shellcheck source=scripts/env-max_m4.sh
  source "$ROOT/scripts/env-max_m4.sh"
  echo "[env] CHUMP_TAURI_FLEET_USE_MAX_M4=1 → sourced scripts/env-max_m4.sh"
fi

c8000="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:8000/v1/models" 2>/dev/null || true)"
c8001="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:8001/v1/models" 2>/dev/null || true)"
[[ -z "$c8000" ]] && c8000="000"
[[ -z "$c8001" ]] && c8001="000"
if [[ "$c8000" == "200" ]]; then
  echo "[preflight] vLLM-MLX :8000 /v1/models → HTTP 200"
elif [[ "$c8001" == "200" ]]; then
  echo "[preflight] vLLM-MLX :8001 /v1/models → HTTP 200 (lite); set OPENAI_API_BASE to http://127.0.0.1:8001/v1 if Chump should use it"
else
  echo "[preflight] WARN: neither :8000 nor :8001 MLX server ready (HTTP ${c8000} / ${c8001}). See docs/operations/INFERENCE_PROFILES.md §1 and §1a" >&2
fi

if [[ "${CHUMP_TAURI_FLEET_SKIP_FMT:-}" != "1" ]]; then
  echo "[fmt] cargo fmt --check"
  cargo fmt --all -- --check
else
  echo "[fmt] skipped (CHUMP_TAURI_FLEET_SKIP_FMT=1)"
fi

if [[ "${CHUMP_TAURI_FLEET_SKIP_CLIPPY:-}" != "1" ]]; then
  echo "[clippy] chump-desktop"
  cargo clippy -p chump-desktop --all-targets -- -D warnings
else
  echo "[clippy] skipped (CHUMP_TAURI_FLEET_SKIP_CLIPPY=1)"
fi

if [[ "${CHUMP_TAURI_FLEET_SKIP_TEST:-}" != "1" ]]; then
  echo "[test] chump-desktop"
  cargo test -p chump-desktop
else
  echo "[test] skipped (CHUMP_TAURI_FLEET_SKIP_TEST=1)"
fi

echo "[check] chump binary (desktop launcher)"
cargo check --bin chump

echo "[check] chump-desktop package"
cargo check -p chump-desktop

if [[ "${CHUMP_TAURI_FLEET_WEB:-}" == "1" ]]; then
  PORT="${CHUMP_TAURI_FLEET_WEB_PORT:-$((31000 + RANDOM % 2000))}"
  echo "[live] Starting chump --web on port ${PORT} (CHUMP_TAURI_FLEET_WEB=1)"
  cleanup() {
    if [[ -n "${WEB_PID:-}" ]] && kill -0 "$WEB_PID" 2>/dev/null; then
      kill "$WEB_PID" 2>/dev/null || true
      wait "$WEB_PID" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT
  CHUMP_WEB_PORT="$PORT" ./run-web.sh &
  WEB_PID=$!
  ok=0
  for _ in $(seq 1 45); do
    if curl -sf --max-time 2 "http://127.0.0.1:${PORT}/api/health" | grep -q chump-web; then
      ok=1
      break
    fi
    sleep 1
  done
  if [[ "$ok" != "1" ]]; then
    echo "[live] FAIL: /api/health on port ${PORT}" >&2
    exit 1
  fi
  echo "[live] OK: GET http://127.0.0.1:${PORT}/api/health"
fi

echo "=== Tauri + MLX fleet: all static checks passed ==="
