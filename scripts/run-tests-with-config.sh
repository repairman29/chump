#!/usr/bin/env bash
# Run a test script against a chosen config (default or max_m4). Applies profile env and runs preflight, then execs the test.
#
# Usage:
#   ./scripts/run-tests-with-config.sh <profile> <test_script> [args...]
#   ./scripts/run-tests-with-config.sh default battle-qa.sh
#   ./scripts/run-tests-with-config.sh max_m4 battle-qa.sh BATTLE_QA_MAX=50
#   ./scripts/run-tests-with-config.sh default run-autonomy-tests.sh
#
# Profiles: default (Ollama 11434) | max_m4 (vLLM-MLX 8000, 14B, inprocess-embed build required).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <profile> <test_script> [args...]" >&2
  echo "  profile: default | max_m4" >&2
  echo "  test_script: e.g. battle-qa.sh, run-autonomy-tests.sh, test-heartbeat-learn.sh" >&2
  echo "Example: $0 max_m4 battle-qa.sh BATTLE_QA_MAX=50" >&2
  exit 1
fi

PROFILE="$1"
TEST_SCRIPT="$2"
shift 2

case "$PROFILE" in
  default|max_m4) ;;
  *)
    echo "Unknown profile: $PROFILE (use default or max_m4)" >&2
    exit 1
    ;;
esac

ENV_FILE="$ROOT/scripts/env-$PROFILE.sh"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Profile env not found: $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

# Preflight: model server reachable (no Discord checks)
if [[ "$OPENAI_API_BASE" == *"11434"* ]]; then
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true)
  if [[ "$code" != "200" ]]; then
    echo "Preflight FAIL: Ollama not reachable on 11434 (got $code). Start: ollama serve && ollama pull qwen2.5:14b" >&2
    exit 1
  fi
  echo "Preflight OK: Ollama reachable at 11434"
else
  # vLLM-MLX exposes /v1/models; ensure we hit the correct path
  preflight_url="${OPENAI_API_BASE%/}/models"
  [[ "$preflight_url" != *"/v1/models" ]] && preflight_url="${OPENAI_API_BASE%/}/v1/models"
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$preflight_url" 2>/dev/null || true)
  if [[ "$code" != "200" ]]; then
    echo "Preflight FAIL: Model server at $OPENAI_API_BASE not reachable (got $code)." >&2
    if [[ "$PROFILE" == "max_m4" ]]; then
      echo "For max_m4: build with cargo build --release --features inprocess-embed and start vLLM-MLX on 8000 only." >&2
    fi
    exit 1
  fi
  echo "Preflight OK: Model server at $OPENAI_API_BASE"
fi

# Test script: accept path (e.g. battle-qa.sh or scripts/qa/run.sh) or bare name
if [[ "$TEST_SCRIPT" == */* ]]; then
  SCRIPT_PATH="$ROOT/$TEST_SCRIPT"
else
  SCRIPT_PATH="$ROOT/scripts/$TEST_SCRIPT"
fi
if [[ ! -f "$SCRIPT_PATH" ]]; then
  echo "Test script not found: $SCRIPT_PATH" >&2
  exit 1
fi

mkdir -p "$ROOT/logs"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] run-tests-with-config: profile=$PROFILE script=$TEST_SCRIPT args=$*" >> "$ROOT/logs/run-tests-with-config.log" 2>/dev/null || true

echo "Running with config: $PROFILE — $TEST_SCRIPT $*"
if [[ -x "$SCRIPT_PATH" ]]; then
  exec "$SCRIPT_PATH" "$@"
else
  exec bash "$SCRIPT_PATH" "$@"
fi
