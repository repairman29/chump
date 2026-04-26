#!/usr/bin/env bash
# Unload Ollama models from memory to free RAM. Uses keep_alive=0 so models
# are evicted immediately after the request (no actual generation).
# Usage: ./scripts/setup/ollama-unload-models.sh [model1 model2 ...]
# With no args, unloads qwen2.5:14b (Chump default). Pass model names to unload those.
#
# To keep models from staying loaded between Chump requests, start Ollama with:
#   OLLAMA_KEEP_ALIVE=0 ollama serve   # unload after each request
#   OLLAMA_KEEP_ALIVE=60 ollama serve  # unload after 60s idle (default is 5m)

set -e
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"

models=("$@")
if [[ ${#models[@]} -eq 0 ]]; then
  models=(qwen2.5:14b)
fi

for model in "${models[@]}"; do
  if curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$OLLAMA_HOST/api/tags" | grep -q 200; then
    echo "Unloading $model..."
    curl -s -X POST "$OLLAMA_HOST/api/generate" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$model\",\"prompt\":\"\",\"keep_alive\":0}" \
      -o /dev/null --max-time 30 || true
  else
    echo "Ollama not reachable at $OLLAMA_HOST; nothing to unload."
    exit 1
  fi
done
echo "Done. If RAM is still high, Ollama often keeps memory until restarted. Run ./scripts/setup/ollama-restart.sh to fully free it."
