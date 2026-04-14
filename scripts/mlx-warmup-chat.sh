#!/usr/bin/env bash
# Time a minimal /v1/chat/completions against vLLM-MLX (isolates MLX from Chump).
# Run from repo root (sources .env when present).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
BASE="${OPENAI_API_BASE:-http://127.0.0.1:8000/v1}"
BASE="${BASE%/}"
MODEL="${OPENAI_MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
HDR=(-H "Content-Type: application/json")
if [[ -n "${OPENAI_API_KEY:-}" && "${OPENAI_API_KEY}" != "not-needed" ]]; then
  HDR+=(-H "Authorization: Bearer ${OPENAI_API_KEY}")
fi
echo "Warmup POST ${BASE}/chat/completions model=${MODEL}"
START="$(date +%s)"
code=$(curl -sS -o /tmp/mlx-warmup-out.json -w '%{http_code}' \
  "${HDR[@]}" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say only: pong\"}],\"max_tokens\":8,\"stream\":false}" \
  "${BASE}/chat/completions" || echo 000)
END="$(date +%s)"
EL=$((END - START))
echo "HTTP ${code} wall_s=${EL}"
if [[ "$code" == "200" ]]; then
  head -c 200 /tmp/mlx-warmup-out.json; echo
else
  cat /tmp/mlx-warmup-out.json 2>/dev/null || true
  exit 1
fi
