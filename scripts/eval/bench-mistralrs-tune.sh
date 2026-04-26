#!/usr/bin/env bash
# Run upstream `mistralrs tune` (hardware / ISQ hints). Not bundled with Chump — install the
# mistral.rs CLI separately (see docs/operations/INFERENCE_PROFILES.md §2b.8).
#
# Usage:
#   ./scripts/eval/bench-mistralrs-tune.sh Qwen/Qwen3-4B
#   ./scripts/eval/bench-mistralrs-tune.sh --json Qwen/Qwen3-4B
#   MISTRALRS_TUNE_PROFILE=fast ./scripts/eval/bench-mistralrs-tune.sh my/model-id
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON=0
MODEL=""
REST=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--json] [MODEL_ID]" >&2
      echo "  MODEL_ID defaults to CHUMP_MISTRALRS_MODEL or Qwen/Qwen3-4B" >&2
      echo "  MISTRALRS_TUNE_PROFILE=quality|fast|... passed as --profile when set" >&2
      exit 0
      ;;
    *) REST+=("$1"); shift ;;
  esac
done
MODEL="${REST[0]:-${CHUMP_MISTRALRS_MODEL:-Qwen/Qwen3-4B}}"
PROFILE="${MISTRALRS_TUNE_PROFILE:-}"
OUT_DIR="${MISTRALRS_TUNE_OUT:-$ROOT/logs}"
mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_BASE="$OUT_DIR/mistralrs-tune-${STAMP}"

if ! command -v mistralrs >/dev/null 2>&1; then
  echo "mistralrs CLI not found on PATH." >&2
  echo "Install per: https://github.com/EricLBuehler/mistral.rs#installation" >&2
  echo "Then map bit-width hints to CHUMP_MISTRALRS_ISQ_BITS (see docs/operations/INFERENCE_PROFILES.md §2b.8)." >&2
  exit 127
fi

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi

ARGS=(tune -m "$MODEL")
if [[ -n "$PROFILE" ]]; then
  ARGS+=(--profile "$PROFILE")
fi

if [[ "$JSON" -eq 1 ]]; then
  JSON_PATH="${OUT_BASE}.json"
  ARGS+=(--json)
  echo "Writing JSON to $JSON_PATH" >&2
  mistralrs "${ARGS[@]}" | tee "$JSON_PATH"
else
  LOG_PATH="${OUT_BASE}.log"
  echo "Writing log to $LOG_PATH" >&2
  mistralrs "${ARGS[@]}" 2>&1 | tee "$LOG_PATH"
fi

echo "Done. For Chump in-process, set e.g. CHUMP_MISTRALRS_ISQ_BITS from recommendations above." >&2
