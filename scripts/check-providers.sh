#!/usr/bin/env bash
# Check all configured cascade providers. See docs/PROVIDER_CASCADE.md.
set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a

# Optional: live usage from Chump Web when reachable
CASCADE_JSON=""
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  WEB_PORT="${CHUMP_WEB_PORT:-3000}"
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://127.0.0.1:${WEB_PORT}/api/cascade-status" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    CASCADE_JSON=$(curl -s -m 5 "http://127.0.0.1:${WEB_PORT}/api/cascade-status" 2>/dev/null || true)
    if ! echo "$CASCADE_JSON" | jq -e .enabled >/dev/null 2>&1; then
      CASCADE_JSON=""
    fi
  fi
fi

echo "=== Provider Cascade Health ==="
echo "    (Slots with RPD configured show daily budget)"

# Slot 0: Local
BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "${BASE}/models" 2>/dev/null || true)
if [[ "$code" == "200" ]]; then
  echo "  [0] local       ✓  ($BASE) — unlimited"
else
  echo "  [0] local       ✗  ($BASE) — HTTP $code"
fi
if [[ -n "$CASCADE_JSON" ]]; then
  ct=$(echo "$CASCADE_JSON" | jq -r '.slots[0].calls_today // empty' 2>/dev/null)
  if [[ -n "$ct" ]]; then
    echo "       → today: $ct"
  fi
fi

# Slots 1-10
for i in $(seq 1 10); do
  enabled_var="CHUMP_PROVIDER_${i}_ENABLED"
  name_var="CHUMP_PROVIDER_${i}_NAME"
  base_var="CHUMP_PROVIDER_${i}_BASE"
  key_var="CHUMP_PROVIDER_${i}_KEY"
  rpd_var="CHUMP_PROVIDER_${i}_RPD"
  rpm_var="CHUMP_PROVIDER_${i}_RPM"
  enabled="${!enabled_var:-}"
  name="${!name_var:-slot_$i}"
  base="${!base_var:-}"
  key="${!key_var:-}"
  rpd="${!rpd_var:-}"
  rpm="${!rpm_var:-}"

  if [[ "$enabled" != "1" || -z "$base" ]]; then
    continue
  fi

  budget=""
  if [[ -n "$rpm" ]]; then budget="RPM=${rpm}"; fi
  if [[ -n "$rpd" ]]; then
    if [[ -n "$budget" ]]; then budget="${budget}, RPD=${rpd}"; else budget="RPD=${rpd}"; fi
  fi
  [[ -z "$budget" ]] && budget="no limits set"

  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    -H "Authorization: Bearer $key" "${base}/models" 2>/dev/null || true)
  padded_name=$(printf "%-12s" "$name")
  if [[ "$code" == "200" ]]; then
    echo "  [$i] ${padded_name} ✓  ($base) — $budget"
  else
    echo "  [$i] ${padded_name} ✗  ($base) — HTTP $code — $budget"
  fi
  if [[ -n "$CASCADE_JSON" ]]; then
    ct=$(echo "$CASCADE_JSON" | jq -r --argjson idx "$i" '.slots[$idx].calls_today // empty' 2>/dev/null)
    rpd=$(echo "$CASCADE_JSON" | jq -r --argjson idx "$i" '.slots[$idx].rpd_limit // empty' 2>/dev/null)
    if [[ -n "$ct" ]]; then
      if [[ -n "$rpd" && "$rpd" != "null" ]]; then
        echo "       → today: $ct / $rpd"
      else
        echo "       → today: $ct"
      fi
    fi
  fi
done

echo ""
echo "Run with CHUMP_LOG_TIMING=1 to see per-call cascade decisions."
echo "See docs/PROVIDER_CASCADE.md for setup and priority routing."
