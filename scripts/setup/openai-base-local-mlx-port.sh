#!/usr/bin/env bash
# Print 8000 or 8001 when OPENAI_API_BASE targets local vLLM-MLX (127.0.0.1 or localhost only).
# Empty output means Ollama, cloud, or another port — callers should not auto-start vLLM.
# Usage (after .env is loaded):  port="$(./scripts/setup/openai-base-local-mlx-port.sh)"
set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi
b="${OPENAI_API_BASE:-}"
[[ "$b" != *127.0.0.1* && "$b" != *localhost* ]] && exit 0
if [[ "$b" == *127.0.0.1:8001* ]] || [[ "$b" == *localhost:8001* ]]; then
  echo 8001
  exit 0
fi
if [[ "$b" == *127.0.0.1:8000* ]] || [[ "$b" == *localhost:8000* ]]; then
  echo 8000
  exit 0
fi
exit 0
