#!/data/data/com.termux/files/usr/bin/bash
# Start Chump companion on Android/Termux: llama.cpp server + Discord bot.
# Place in ~/chump/start-companion.sh on the Pixel.
#
# Usage:
#   ./start-companion.sh           # start both llama-server and Chump
#   ./start-companion.sh --bot     # start Chump only (server already running)
#   ./start-companion.sh --server  # start llama-server only

set -e
cd ~/chump

# --- Config ---
MODEL="${CHUMP_MODEL:-$HOME/models/Qwen3-4B-Q4_K_M.gguf}"
PORT="${CHUMP_PORT:-8000}"
CTX_SIZE="${CHUMP_CTX_SIZE:-4096}"
GPU_LAYERS="${CHUMP_GPU_LAYERS:-99}"
LLAMA_SERVER="${CHUMP_LLAMA_SERVER:-$HOME/llama.cpp/build/bin/llama-server}"
SERVER_WAIT="${CHUMP_SERVER_WAIT:-120}"  # seconds to wait for server

# --- Load env ---
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

# --- Functions ---
start_server() {
  if curl -s "http://127.0.0.1:${PORT}/v1/models" > /dev/null 2>&1; then
    echo "llama-server already running on port ${PORT}."
    return 0
  fi

  if [[ ! -f "$LLAMA_SERVER" ]]; then
    echo "Error: llama-server not found at $LLAMA_SERVER"
    echo "Build it: cd ~/llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build -j\$(nproc)"
    exit 1
  fi

  if [[ ! -f "$MODEL" ]]; then
    echo "Error: Model not found at $MODEL"
    echo "Download: bash ~/chump/scripts/setup/switch-mabel-to-qwen3-4b.sh"
    echo "Or: curl -L -o $MODEL https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"
    exit 1
  fi

  echo "Starting llama-server (model: $(basename "$MODEL"), port: ${PORT}, GPU layers: ${GPU_LAYERS})..."
  "$LLAMA_SERVER" \
    --model "$MODEL" \
    --port "$PORT" \
    --host 127.0.0.1 \
    --n-gpu-layers "$GPU_LAYERS" \
    --ctx-size "$CTX_SIZE" \
    --chat-template chatml \
    > logs/llama-server.log 2>&1 &

  echo "Waiting for model server (up to ${SERVER_WAIT}s)..."
  server_up=0
  for i in $(seq 1 "$SERVER_WAIT"); do
    if curl -s "http://127.0.0.1:${PORT}/v1/models" > /dev/null 2>&1; then
      echo "HTTP server up (${i}s). Waiting for model to load..."
      server_up=1
      break
    fi
    sleep 1
  done
  if [[ "$server_up" -ne 1 ]]; then
    echo "Error: Model server did not start within ${SERVER_WAIT}s."
    echo "Check logs/llama-server.log"
    exit 1
  fi
  # llama-server can return 200 on /v1/models before the model is loaded; /v1/chat/completions returns 503 until ready.
  MODEL_READY_WAIT="${CHUMP_MODEL_READY_WAIT:-90}"
  for i in $(seq 1 "$MODEL_READY_WAIT"); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST -H "Content-Type: application/json" \
      -d '{"model":"default","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
      "http://127.0.0.1:${PORT}/v1/chat/completions" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
      echo "Model ready (${i}s)."
      return 0
    fi
    [[ $((i % 5)) -eq 0 ]] && echo "  ... model still loading (${i}s, last HTTP ${code})"
    sleep 1
  done

  echo "Error: Model did not become ready within ${MODEL_READY_WAIT}s (server may return 503 'model not loaded' until load finishes)."
  echo "Check logs/llama-server.log"
  exit 1
}

start_bot() {
  if [[ -z "$DISCORD_TOKEN" ]]; then
    echo "Error: DISCORD_TOKEN not set. Add it to .env"
    exit 1
  fi

  # Check server is up
  if ! curl -s "http://127.0.0.1:${PORT}/v1/models" > /dev/null 2>&1; then
    echo "Error: Model server not running on port ${PORT}. Start it first or run without --bot."
    exit 1
  fi

  # Guard against duplicate bots
  if pgrep -f "chump.*--discord" > /dev/null 2>&1; then
    echo "Chump Discord bot is already running. Stop it first: pkill -f 'chump.*--discord'"
    exit 1
  fi

  export OPENAI_API_BASE="http://127.0.0.1:${PORT}/v1"
  export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
  export OPENAI_MODEL="${OPENAI_MODEL:-default}"

  echo "Starting Chump Discord bot..."
  exec ./chump --discord
}

# --- Main ---
case "${1:-}" in
  --server)
    start_server
    echo "Server running. Start the bot with: ./start-companion.sh --bot"
    ;;
  --bot)
    start_bot
    ;;
  *)
    # Default: start both
    termux-wake-lock 2>/dev/null || true
    start_server
    start_bot
    ;;
esac
