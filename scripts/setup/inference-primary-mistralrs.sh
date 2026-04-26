#!/usr/bin/env bash
# Exit 0 when the environment selects in-process mistral.rs as Chump's primary LLM
# (same predicate as Rust env_flags::chump_inference_backend_mistralrs_env):
#   CHUMP_INFERENCE_BACKEND=mistralrs (case-insensitive) and non-empty CHUMP_MISTRALRS_MODEL.
#
# Used by run-web.sh, run-discord-full.sh, keep-chump-online.sh so we do not auto-start
# vLLM-MLX or Ollama beside an in-process model.
#
# Usage: if "$CHUMP_HOME/scripts/setup/inference-primary-mistralrs.sh"; then ...; fi
set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi
be="${CHUMP_INFERENCE_BACKEND:-}"
mdl="${CHUMP_MISTRALRS_MODEL:-}"
mdl_trim="${mdl//[[:space:]]/}"
case "$be" in
  [Mm][Ii][Ss][Tt][Rr][Aa][Ll][Rr][Ss]) ;;
  *) exit 1 ;;
esac
[[ -n "$mdl_trim" ]] || exit 1
exit 0
