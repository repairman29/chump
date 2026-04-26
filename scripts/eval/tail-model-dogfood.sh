#!/usr/bin/env bash
# Follow logs while you run battle QA, web dogfood, or heartbeats (one terminal).
#
# Usage:
#   ./scripts/eval/tail-model-dogfood.sh
#   CHUMP_TAIL_LOGS="logs/battle-pwa-live.log,logs/discord.log" ./scripts/eval/tail-model-dogfood.sh
#
# Default files (only those that exist are opened): logs/battle-qa.log, logs/chump.log
# CHUMP_TAIL_LOGS: comma-separated paths relative to repo root (e.g. logs/vllm-mlx-8000.log)
set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

collect() {
  local -a out=()
  local p f
  for p in "$@"; do
    [[ -z "$p" ]] && continue
    f="$ROOT/${p#./}"
    [[ -f "$f" ]] && out+=("$f")
  done
  printf '%s\n' "${out[@]}"
}

paths=()
while IFS= read -r line; do
  [[ -n "$line" ]] && paths+=("$line")
done < <(collect logs/battle-qa.log logs/chump.log)

if [[ -n "${CHUMP_TAIL_LOGS:-}" ]]; then
  IFS=',' read -ra extra <<< "${CHUMP_TAIL_LOGS}"
  for raw in "${extra[@]}"; do
    p="${raw#"${raw%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -z "$p" ]] && continue
    while IFS= read -r line; do
      [[ -n "$line" ]] && paths+=("$line")
    done < <(collect "$p")
  done
fi

# Drop duplicates (same path from defaults + CHUMP_TAIL_LOGS); bash 3.2–safe
_u="$(mktemp)"
printf '%s\n' "${paths[@]}" | sort -u > "$_u"
paths=()
while IFS= read -r line; do [[ -n "$line" ]] && paths+=("$line"); done < "$_u"
rm -f "$_u"

if [[ ${#paths[@]} -eq 0 ]]; then
  echo "No log files found yet under $ROOT/logs/." >&2
  echo "Start something first, then re-run:" >&2
  echo "  • Web / PWA dogfood: ./run-web.sh or chump --web  → logs/chump.log" >&2
  echo "  • Battle QA: BATTLE_QA_MAX=5 ./scripts/ci/battle-qa.sh  → logs/battle-qa.log" >&2
  echo "Optional: CHUMP_TAIL_LOGS=logs/discord.log,logs/battle-pwa-live.log $0" >&2
  exit 1
fi

echo "== tail-model-dogfood: ${#paths[@]} file(s) (Ctrl+C to stop) ==" >&2
for f in "${paths[@]}"; do
  echo "  $f" >&2
done
echo "" >&2
exec tail -F "${paths[@]}"
