#!/usr/bin/env bash
# Fleet health check: verify Mac + Pixel bots are up and responding after a deploy.
# Outputs a concise pass/fail table. Exit 0 if all checks pass, 1 if any fail.
#
# Usage:
#   ./scripts/fleet-health.sh           # check Mac + Pixel
#   ./scripts/fleet-health.sh --mac     # Mac only
#   ./scripts/fleet-health.sh --pixel   # Pixel only
#   ./scripts/fleet-health.sh --watch   # loop every 30s until all pass (or Ctrl-C)
#
# Env: PIXEL_SSH_HOST, PIXEL_SSH_PORT (8022), PIXEL_MODEL_PORT (8000),
#      CHUMP_WEB_PORT (3000), FLEET_HEALTH_TIMEOUT (8s per probe)

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a

CHECK_MAC=1
CHECK_PIXEL=1
WATCH=0
for arg in "$@"; do
  case "$arg" in
    --mac)   CHECK_PIXEL=0 ;;
    --pixel) CHECK_MAC=0 ;;
    --watch) WATCH=1 ;;
  esac
done

PIXEL_HOST="${PIXEL_SSH_HOST:-termux}"
PIXEL_PORT="${PIXEL_SSH_PORT:-8022}"
PIXEL_MODEL_PORT="${PIXEL_MODEL_PORT:-8000}"
WEB_PORT="${CHUMP_WEB_PORT:-3000}"
TIMEOUT="${FLEET_HEALTH_TIMEOUT:-8}"
SSH_OPTS=(-o ConnectTimeout="$TIMEOUT" -o BatchMode=yes -o StrictHostKeyChecking=no -p "$PIXEL_PORT")

# --- Probe helpers ---
PASS="✓"
FAIL="✗"
WARN="~"
RESULTS=()
ALL_PASS=1

check() {
  local label="$1" result="$2" detail="${3:-}"
  local icon
  if [[ "$result" == "pass" ]]; then icon="$PASS"; else icon="$FAIL"; ALL_PASS=0; fi
  local line="  $icon  $label"
  [[ -n "$detail" ]] && line="$line — $detail"
  RESULTS+=("$line")
}

warn() {
  local label="$1" detail="${2:-}"
  local line="  $WARN  $label"
  [[ -n "$detail" ]] && line="$line — $detail"
  RESULTS+=("$line")
}

run_checks() {
  RESULTS=()
  ALL_PASS=1
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo ""
  echo "=== Fleet Health ($ts) ==="

  # ---- Mac checks ----
  if [[ "$CHECK_MAC" -eq 1 ]]; then
    echo ""
    echo "Mac:"

    # Discord bot process
    if pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
      local dpid; dpid=$(pgrep -f "rust-agent.*--discord" | head -1)
      check "Discord bot" "pass" "PID $dpid"
    else
      check "Discord bot" "fail" "not running — run: nohup ./run-discord.sh >> logs/discord.log 2>&1 &"
    fi

    # Web bot process
    if pgrep -f "rust-agent.*--web" >/dev/null 2>&1; then
      local wpid; wpid=$(pgrep -f "rust-agent.*--web" | head -1)
      check "Web bot" "pass" "PID $wpid"
    else
      check "Web bot" "fail" "not running — run: nohup ./target/release/rust-agent --web --port $WEB_PORT >> logs/web.log 2>&1 &"
    fi

    # Web API health endpoint
    local web_code
    web_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "http://127.0.0.1:${WEB_PORT}/api/health" 2>/dev/null || echo "000")
    if [[ "$web_code" == "200" ]]; then
      check "Web API /health" "pass" "HTTP $web_code"
    else
      check "Web API /health" "fail" "HTTP $web_code (port $WEB_PORT)"
    fi

    # Local model (8000 vLLM-MLX or 11434 Ollama)
    local model_ok=0 model_detail
    local api_base="${OPENAI_API_BASE:-http://localhost:8000/v1}"
    local model_code
    model_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "${api_base}/models" 2>/dev/null || echo "000")
    if [[ "$model_code" == "200" ]]; then
      check "Local model ($api_base)" "pass" "HTTP $model_code"
    else
      # fallback check Ollama
      local ollama_code
      ollama_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "http://127.0.0.1:11434/api/tags" 2>/dev/null || echo "000")
      if [[ "$ollama_code" == "200" ]]; then
        check "Local model (Ollama 11434)" "pass" "HTTP $ollama_code"
      else
        check "Local model" "fail" "8000=$model_code, Ollama=$ollama_code"
      fi
    fi

    # Cascade status (informational)
    local cascade_code
    cascade_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "http://127.0.0.1:${WEB_PORT}/api/cascade-status" 2>/dev/null || echo "000")
    if [[ "$cascade_code" == "200" ]]; then
      local slots_on
      slots_on=$(curl -s --max-time 4 "http://127.0.0.1:${WEB_PORT}/api/cascade-status" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(1 for s in d.get('slots',[]) if s.get('enabled')))" 2>/dev/null || echo "?")
      warn "Cascade" "$slots_on slots enabled"
    fi

    # Discord bot last log line (sanity)
    local last_discord_log
    last_discord_log=$(tail -1 logs/discord.log 2>/dev/null | cut -c1-120 || true)
    [[ -n "$last_discord_log" ]] && warn "Last discord.log" "$last_discord_log"

    for r in "${RESULTS[@]}"; do echo "$r"; done
    RESULTS=()
  fi

  # ---- Pixel / Mabel checks ----
  if [[ "$CHECK_PIXEL" -eq 1 ]]; then
    echo ""
    echo "Pixel (Mabel):"

    local pixel_ssh_ok=0
    local pixel_out
    pixel_out=$(ssh "${SSH_OPTS[@]}" "$PIXEL_HOST" \
      "pgrep -f 'chump.*--discord' 2>/dev/null | wc -l | tr -d ' '; \
       curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:${PIXEL_MODEL_PORT}/v1/models 2>/dev/null || echo 000; \
       tail -1 ~/chump/logs/companion.log 2>/dev/null | cut -c1-120 || true" \
      2>/dev/null) && pixel_ssh_ok=1 || true

    if [[ "$pixel_ssh_ok" -eq 0 ]]; then
      check "Pixel SSH" "fail" "cannot reach $PIXEL_HOST:$PIXEL_PORT"
    else
      check "Pixel SSH" "pass" "$PIXEL_HOST:$PIXEL_PORT"

      local bot_count model_code last_log
      bot_count=$(echo "$pixel_out" | sed -n '1p')
      model_code=$(echo "$pixel_out" | sed -n '2p')
      last_log=$(echo "$pixel_out"   | sed -n '3p')

      if [[ "${bot_count:-0}" -gt 0 ]]; then
        check "Mabel Discord bot" "pass" "$bot_count process(es)"
      else
        check "Mabel Discord bot" "fail" "not running — run: ssh -p $PIXEL_PORT $PIXEL_HOST 'cd ~/chump && nohup bash start-companion.sh --bot >> logs/companion.log 2>&1 &'"
      fi

      if [[ "${model_code:-000}" == "200" ]]; then
        check "Pixel model (llama-server :$PIXEL_MODEL_PORT)" "pass" "HTTP $model_code"
      else
        check "Pixel model (llama-server :$PIXEL_MODEL_PORT)" "fail" "HTTP ${model_code:-000}"
      fi

      [[ -n "${last_log:-}" ]] && warn "Last companion.log" "$last_log"
    fi

    for r in "${RESULTS[@]}"; do echo "$r"; done
    RESULTS=()
  fi

  echo ""
  if [[ "$ALL_PASS" -eq 1 ]]; then
    echo "All checks passed."
  else
    echo "Some checks FAILED. See above for remediation hints."
  fi
  echo ""
  return $((1 - ALL_PASS))
}

if [[ "$WATCH" -eq 1 ]]; then
  while true; do
    run_checks && break
    echo "Retrying in 30s... (Ctrl-C to stop)"
    sleep 30
  done
else
  run_checks
fi
