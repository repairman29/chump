#!/usr/bin/env bash
# Capture OOM/crash context: vLLM log tail, vm_stat, top processes, VLLM_* env, port 8000 status.
# Run after a crash or let restart-vllm-if-down.sh call this before restarting vLLM.
# Usage: ./scripts/capture-oom-context.sh [N]
#   N = last N lines of vLLM log (default 200). Output: logs/oom-context-<YYYYMMDD-HHMMSS>.txt

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
N="${1:-200}"
[[ "$N" =~ ^[0-9]+$ ]] || N=200
mkdir -p "$ROOT/logs"
OUT="$ROOT/logs/oom-context-$(date +%Y%m%d-%H%M%S).txt"

{
  echo "=== OOM / crash context capture ==="
  echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""

  echo "--- Last $N lines of logs/vllm-mlx-8000.log ---"
  if [[ -f "$ROOT/logs/vllm-mlx-8000.log" ]]; then
    tail -n "$N" "$ROOT/logs/vllm-mlx-8000.log"
  else
    echo "(file not found)"
  fi
  echo ""

  echo "--- vm_stat ---"
  vm_stat 2>/dev/null || echo "(vm_stat not available)"
  echo ""

  echo "--- Top 20 processes by RSS ---"
  ps -eo pid,rss,comm 2>/dev/null | sort -k2 -rn | head -20 || echo "(ps failed)"
  echo ""

  echo "--- VLLM_* and OPENAI_API_BASE from .env (values redacted) ---"
  if [[ -f "$ROOT/.env" ]]; then
    grep -E '^(VLLM_[A-Za-z0-9_]*|OPENAI_API_BASE)=' "$ROOT/.env" 2>/dev/null | while IFS= read -r line; do
      key="${line%%=*}"
      echo "${key}=<set>"
    done
  else
    echo "(no .env)"
  fi
  echo ""

  echo "--- Port 8000 ---"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:8000/v1/models" 2>/dev/null || echo "000")
  echo "HTTP $code"
} >> "$OUT" 2>&1

echo "Context written to $OUT"
