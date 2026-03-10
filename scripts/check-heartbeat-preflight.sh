#!/usr/bin/env bash
# Check which model port is ready for the heartbeat (8000 or 8001). No .env or agent run.
# Exit 0 and print the port; exit 1 if neither is ready. Use before running heartbeat-learn.sh.

model_ready() {
  local port=$1
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${port}/v1/models" 2>/dev/null || true
}

if [[ "$(model_ready 8000)" == "200" ]]; then
  echo "8000"
  exit 0
fi
if [[ "$(model_ready 8001)" == "200" ]]; then
  echo "8001"
  exit 0
fi
echo "No model server on 8000 or 8001. Start vLLM (e.g. scripts/serve-vllm-mlx.sh or warm-the-ovens.sh)." >&2
exit 1
