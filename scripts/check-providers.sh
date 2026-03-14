#!/usr/bin/env bash
# Check all configured cascade providers. See docs/PROVIDER_CASCADE.md.
set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a

echo "=== Provider Cascade Health ==="

# Slot 0: Local
BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${BASE}/models" 2>/dev/null || true)
if [[ "$code" == "200" ]]; then
  echo "  [0] local       ✓  ($BASE)"
else
  echo "  [0] local       ✗  ($BASE) — HTTP $code"
fi

# Slots 1-9
for i in $(seq 1 9); do
  enabled_var="CHUMP_PROVIDER_${i}_ENABLED"
  name_var="CHUMP_PROVIDER_${i}_NAME"
  base_var="CHUMP_PROVIDER_${i}_BASE"
  key_var="CHUMP_PROVIDER_${i}_KEY"
  enabled="${!enabled_var:-}"
  name="${!name_var:-slot_$i}"
  base="${!base_var:-}"
  key="${!key_var:-}"
  if [[ "$enabled" != "1" || -z "$base" ]]; then
    continue
  fi
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    -H "Authorization: Bearer $key" "${base}/models" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    echo "  [$i] $name       ✓  ($base)"
  else
    echo "  [$i] $name       ✗  ($base) — HTTP $code"
  fi
done
