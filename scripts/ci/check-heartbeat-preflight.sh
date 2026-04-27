#!/usr/bin/env bash
# Preflight for autonomy/heartbeat: is the model server reachable?
# Prints "11434", "8000", "8001" if local is up, or "cascade:N" if a cloud slot (CHUMP_PROVIDER_N_*)
# is reachable when CHUMP_CASCADE_ENABLED=1 and local is down. Exits 0 on success, 1 if nothing answers.
# Respects OPENAI_API_BASE: if it points to 8000/8001, check that port first; else check Ollama (11434).

set -e

# Source .env from repo root if vars are not already in the environment (standalone invocation).
SCRIPT_ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
if [[ -z "${CHUMP_CASCADE_ENABLED:-}" && -f "$SCRIPT_ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_ROOT/.env"
  set +a
fi

BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"

# Reject absurd localhost ports (typos / test leftovers like :9) before probing.
# Allowed local ports: 11434 (Ollama), 8000/8001 (vLLM-MLX). Cloud URLs (no localhost) skip this check.
if [[ "$BASE" == *"127.0.0.1"* ]] || [[ "$BASE" == *"localhost"* ]]; then
  port_from_base=""
  [[ "$BASE" =~ :([0-9]+)(/|$) ]] && port_from_base="${BASH_REMATCH[1]}"
  if [[ -n "$port_from_base" ]]; then
    case "$port_from_base" in
      11434|8000|8001) ;;
      *)
        echo "check-heartbeat-preflight: Invalid OPENAI_API_BASE for local host: port ${port_from_base} is not allowed (use 11434, 8000, or 8001, or a cloud URL). Fix .env." >&2
        exit 1
        ;;
    esac
  fi
fi

if [[ "$BASE" == *"11434"* ]]; then
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true)
  if [[ "$code" == "200" ]]; then
    echo "11434"
    exit 0
  fi
  # Ollama not up; fall through to cascade check below
else
  # Non-Ollama: extract port from OPENAI_API_BASE (e.g. :8000 or :8001) and check it first, then fallback
  port_from_base=""
  [[ "$BASE" =~ :([0-9]+)(/|$) ]] && port_from_base="${BASH_REMATCH[1]}"
  for port in $port_from_base 8000 8001; do
    [[ -z "$port" ]] && continue
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${port}/v1/models" 2>/dev/null || true)
    if [[ "$code" == "200" ]]; then
      echo "$port"
      exit 0
    fi
  done
  # Local vLLM not up; fall through to cascade check below
fi

# Cascade fallback: if CHUMP_CASCADE_ENABLED=1, probe cloud slots (CHUMP_PROVIDER_{N}_*).
# The cascade env vars are exported by calling scripts (set -a; source .env) or sourced above.
if [[ "${CHUMP_CASCADE_ENABLED:-}" == "1" ]]; then
  for n in 1 2 3 4 5 6 7 8 9; do
    enabled_var="CHUMP_PROVIDER_${n}_ENABLED"
    base_var="CHUMP_PROVIDER_${n}_BASE"
    key_var="CHUMP_PROVIDER_${n}_KEY"
    slot_enabled="${!enabled_var:-}"
    slot_base="${!base_var:-}"
    slot_key="${!key_var:-}"
    [[ "$slot_enabled" != "1" || -z "$slot_base" ]] && continue
    probe_url="${slot_base%/}/models"
    if [[ -n "$slot_key" ]]; then
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        -H "Authorization: Bearer ${slot_key}" "${probe_url}" 2>/dev/null || true)
    else
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${probe_url}" 2>/dev/null || true)
    fi
    if [[ "$code" == "200" ]]; then
      echo "cascade:${n}"
      exit 0
    fi
  done
fi

exit 1
