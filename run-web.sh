#!/usr/bin/env bash
# Run the Chump Web PWA. Ensures vLLM-MLX is up when .env points at local :8000 or :8001, then starts the web server.
# Usage: ./run-web.sh [--port 3000]
# Set CHUMP_HOME (or run from repo root) so web/ and logs are found. Optional: CHUMP_WEB_PORT=3001

set -e
cd "$(dirname "$0")"
export CHUMP_HOME="${CHUMP_HOME:-$(pwd)}"
export CHUMP_REPO="${CHUMP_REPO:-$CHUMP_HOME}"
# Serve Chump repo web/ so the Chump PWA (Dashboard, Briefing, chat, etc.) is used. Override with CHUMP_WEB_STATIC_DIR if needed.
export CHUMP_WEB_STATIC_DIR="${CHUMP_WEB_STATIC_DIR:-$CHUMP_REPO/web}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
export CHUMP_REPO="${CHUMP_REPO:-$CHUMP_HOME}"
export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
if [[ "${CHUMP_GOLDEN_PATH_OLLAMA:-}" == "1" ]]; then
  export OPENAI_API_BASE="http://localhost:11434/v1"
  export OPENAI_API_KEY="ollama"
  export OPENAI_MODEL="qwen2.5:14b"
fi

# In-process mistral.rs primary: do not start vLLM-MLX or touch Ollama here (avoids two LLMs on Metal/RAM).
if [[ -x "$CHUMP_HOME/scripts/setup/inference-primary-mistralrs.sh" ]] && "$CHUMP_HOME/scripts/setup/inference-primary-mistralrs.sh" 2>/dev/null; then
  echo "Primary inference: mistral.rs in-process (CHUMP_MISTRALRS_MODEL set). Skipping vLLM-MLX / Ollama startup."
else
  # When .env points at local vLLM-MLX (8000 or 8001), stop Ollama (GPU/RAM) then try to ensure MLX is up.
  MLX_PORT="$(bash "$CHUMP_HOME/scripts/setup/openai-base-local-mlx-port.sh" 2>/dev/null || true)"
  if [[ "$MLX_PORT" == "8000" || "$MLX_PORT" == "8001" ]] && [[ -x "$CHUMP_HOME/scripts/setup/stop-ollama-if-running.sh" ]]; then
    bash "$CHUMP_HOME/scripts/setup/stop-ollama-if-running.sh" || true
  fi
  if [[ "$MLX_PORT" == "8000" ]]; then
    if [[ -x "$CHUMP_HOME/scripts/setup/restart-vllm-if-down.sh" ]]; then
      echo "Ensuring model server (8000) is up..."
      "$CHUMP_HOME/scripts/setup/restart-vllm-if-down.sh" || true
    fi
  elif [[ "$MLX_PORT" == "8001" ]]; then
    if [[ -x "$CHUMP_HOME/scripts/setup/restart-vllm-8001-if-down.sh" ]]; then
      echo "Ensuring model server (8001, lite MLX) is up..."
      "$CHUMP_HOME/scripts/setup/restart-vllm-8001-if-down.sh" || true
    fi
  fi
  if [[ "$MLX_PORT" == "8000" || "$MLX_PORT" == "8001" ]]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${MLX_PORT}/v1/models" 2>/dev/null || true)
    [[ -z "$code" ]] && code="000"
    if [[ "$code" != "200" ]]; then
      echo "Warn: vLLM-MLX on ${MLX_PORT} not responding (HTTP $code). PWA will start but chat may fail."
      if [[ "$MLX_PORT" == "8000" ]]; then
        echo "  Start: $CHUMP_HOME/scripts/setup/restart-vllm-if-down.sh  or  ./serve-vllm-mlx.sh"
      else
        echo "  Start: $CHUMP_HOME/scripts/setup/restart-vllm-8001-if-down.sh  or  ./scripts/setup/serve-vllm-mlx-8001.sh"
      fi
    fi
  fi
fi

mkdir -p logs
PORT="${CHUMP_WEB_PORT:-3000}"
if [[ "$1" == "--port" ]] && [[ -n "${2:-}" ]]; then
  PORT="$2"
  shift 2
fi
# If Chump web is already up on this port, do not start a second process (avoids "address already in use" spam in logs/chump-web.log).
health="$(curl -s --max-time 2 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || true)"
if [[ "$health" == *chump-web* ]]; then
  echo "Chump web already responds on http://127.0.0.1:${PORT} (GET /api/health). Not starting another."
  exit 0
fi
if [[ -x ./target/release/chump ]]; then
  exec ./target/release/chump --web --port "$PORT" "$@"
elif [[ -x ./target/debug/chump ]]; then
  exec ./target/debug/chump --web --port "$PORT" "$@"
elif [[ -x ./target/release/chump ]]; then
  exec ./target/release/chump --web --port "$PORT" "$@"
elif [[ -x ./target/debug/chump ]]; then
  exec ./target/debug/chump --web --port "$PORT" "$@"
fi
# Workspace has multiple binaries; `cargo run` requires --bin chump.
if [[ "${CHUMP_USE_RELEASE:-}" == "1" ]]; then
  exec cargo run --release --bin chump -- --web --port "$PORT" "$@"
fi
exec cargo run --bin chump -- --web --port "$PORT" "$@"
