#!/usr/bin/env bash
# Wait for 8000 to be ready, then start self-improve and cursor-improve heartbeat loops in background.
# Usage: ./scripts/dev/start-self-improve-cycles.sh
# Logs: logs/heartbeat-self-improve.log, logs/heartbeat-cursor-improve-loop.log

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export CHUMP_TEST_CONFIG="max_m4"
[[ -f "$ROOT/scripts/dev/env-max_m4.sh" ]] && source "$ROOT/scripts/dev/env-max_m4.sh"

echo "Waiting for model server on 8000 (max 10 min)..."
deadline=$(($(date +%s) + 600))
while [[ $(date +%s) -lt $deadline ]]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:8000/v1/models" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    echo "8000 ready. Starting self-improve and cursor-improve cycles."
    nohup bash "$ROOT/scripts/dev/heartbeat-self-improve.sh" >> "$ROOT/logs/heartbeat-self-improve.log" 2>&1 &
    echo "  heartbeat-self-improve PID: $!"
    nohup bash "$ROOT/scripts/dev/heartbeat-cursor-improve-loop.sh" >> "$ROOT/logs/heartbeat-cursor-improve-loop.log" 2>&1 &
    echo "  heartbeat-cursor-improve-loop PID: $!"
    echo "Done. Tail logs: tail -f logs/heartbeat-self-improve.log logs/heartbeat-cursor-improve-loop.log"
    exit 0
  fi
  sleep 15
done
echo "Timeout: 8000 not ready. Start vLLM with: ./serve-vllm-mlx.sh" >&2
exit 1
