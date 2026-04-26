#!/usr/bin/env bash
# shellcheck shell=bash
# Configure OPENAI_* for neuromod study drivers (run-study1.sh … run-study5.sh).
#
# Opt-in: Together cloud is used only when BOTH are set:
#   CHUMP_TOGETHER_CLOUD=1
#   CHUMP_TOGETHER_JOB_REF=<budget ticket URL or id>
#   TOGETHER_API_KEY
#
# If TOGETHER_API_KEY is set but CHUMP_TOGETHER_CLOUD is not 1, Together is
# skipped (avoids surprise spend from a long-lived .env).
#
# Usage (after ROOT + load_env):
#   # shellcheck source=scripts/lib/together-study-inference.sh
#   source "${ROOT}/scripts/lib/together-study-inference.sh"
#   together_study_inference_or_exit study1 || exit $?

together_study_inference_or_exit() {
  local tag="${1:?tag}"

  if [[ -n "${TOGETHER_API_KEY:-}" && "${CHUMP_TOGETHER_CLOUD:-}" == "1" ]]; then
    if [[ -z "${CHUMP_TOGETHER_JOB_REF:-}" ]]; then
      echo "ERROR: [${tag}] CHUMP_TOGETHER_CLOUD=1 requires CHUMP_TOGETHER_JOB_REF (budget ticket)." >&2
      echo "See docs/operations/TOGETHER_SPEND.md" >&2
      return 3
    fi
    export OPENAI_API_BASE="https://api.together.xyz/v1"
    export OPENAI_API_KEY="${TOGETHER_API_KEY}"
    export OPENAI_MODEL="${MODEL:-meta-llama/Llama-3.3-70B-Instruct-Turbo}"
    echo "[${tag}] inference=Together cloud  model=${OPENAI_MODEL}  job_ref=${CHUMP_TOGETHER_JOB_REF}"
    return 0
  fi

  if [[ -n "${TOGETHER_API_KEY:-}" && "${CHUMP_TOGETHER_CLOUD:-}" != "1" ]]; then
    echo "[${tag}] note: TOGETHER_API_KEY is set but CHUMP_TOGETHER_CLOUD≠1 — skipping Together cloud (use Ollama or OPENAI_API_BASE from .env)." >&2
  fi

  if [[ -z "${OPENAI_API_BASE:-}" ]]; then
    if command -v curl >/dev/null 2>&1 && curl -sf --connect-timeout 2 "http://127.0.0.1:11434/v1/models" >/dev/null 2>&1; then
      export OPENAI_API_BASE="http://127.0.0.1:11434/v1"
      export OPENAI_API_KEY="ollama"
      export OPENAI_MODEL="${MODEL:-qwen2.5:7b}"
      echo "[${tag}] inference=Ollama  model=${OPENAI_MODEL}"
      return 0
    fi
    echo "ERROR: [${tag}] No inference endpoint. Options: (1) CHUMP_TOGETHER_CLOUD=1 and CHUMP_TOGETHER_JOB_REF=<ticket> with TOGETHER_API_KEY for Together, (2) set OPENAI_API_BASE in .env, or (3) start Ollama." >&2
    return 3
  fi

  [[ -n "${MODEL:-}" ]] && export OPENAI_MODEL="$MODEL"
  echo "[${tag}] inference=env OPENAI_API_BASE  model=${OPENAI_MODEL:-?} @ ${OPENAI_API_BASE}"
  return 0
}
