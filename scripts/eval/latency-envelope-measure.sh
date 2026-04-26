#!/usr/bin/env bash
# Latency envelope measurement: run N iterations of Scenario A (no-tool) and B (3-tool),
# compute median/p90, append results to docs/operations/LATENCY_ENVELOPE.md and JSONL log.
#
# Usage (from repo root, with web server running):
#   ./scripts/eval/latency-envelope-measure.sh
#   LATENCY_N=5 ./scripts/eval/latency-envelope-measure.sh
#
# Requires: curl, jq (optional for richer output), web server on CHUMP_WEB_PORT.
# Set CHUMP_WEB_TOKEN in env if auth is required.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/logs"

N="${LATENCY_N:-10}"
HOST="${CHUMP_WEB_HOST:-127.0.0.1}"
PORT="${CHUMP_WEB_PORT:-3000}"
TOKEN="${CHUMP_WEB_TOKEN:-}"
BASE="http://${HOST}:${PORT}"
DATE_UTC="$(date -u +%Y-%m-%d)"
LOG="$ROOT/logs/latency-envelope-${DATE_UTC}.jsonl"
DOC="$ROOT/docs/operations/LATENCY_ENVELOPE.md"
OPERATOR="${LATENCY_OPERATOR:-auto}"

PROMPT_A="Say hello in exactly one sentence."
PROMPT_B="List my open tasks, then check stack status, then give me a status report."

# --- helpers ---

auth_header() {
  if [[ -n "$TOKEN" ]]; then
    echo "Authorization: Bearer $TOKEN"
  else
    echo "X-No-Auth: 1"
  fi
}

# Measure wall time of a single chat turn via SSE. Returns milliseconds.
measure_turn() {
  local prompt="$1"
  local session_id="$2"
  local start_ms end_ms

  if command -v gdate &>/dev/null; then
    start_ms=$(gdate +%s%3N)
  else
    start_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || date +%s000)
  fi

  # POST /api/chat with SSE; wait for turn_complete or turn_error event
  curl -s -N \
    -H "Content-Type: application/json" \
    -H "$(auth_header)" \
    -d "{\"message\":$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),\"session_id\":\"$session_id\"}" \
    "${BASE}/api/chat" 2>/dev/null | while IFS= read -r line; do
      if echo "$line" | grep -q "event: turn_complete\|event: turn_error"; then
        break
      fi
    done

  if command -v gdate &>/dev/null; then
    end_ms=$(gdate +%s%3N)
  else
    end_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || date +%s000)
  fi

  echo $(( end_ms - start_ms ))
}

# Create a session and return session_id
create_session() {
  local resp
  resp=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "$(auth_header)" \
    -d '{"bot":"chump"}' \
    "${BASE}/api/sessions" 2>/dev/null)
  echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo ""
}

# Delete a session
delete_session() {
  local sid="$1"
  curl -s -X DELETE -H "$(auth_header)" "${BASE}/api/sessions/${sid}" >/dev/null 2>&1 || true
}

# Get model info from stack-status
get_model_info() {
  curl -s -H "$(auth_header)" "${BASE}/api/stack-status" 2>/dev/null | \
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    model = d.get('openai_model') or d.get('inference',{}).get('mistralrs_model') or 'unknown'
    print(model)
except:
    print('unknown')
" 2>/dev/null || echo "unknown"
}

# Compute median from sorted array (passed as args)
compute_median() {
  local -a sorted=("$@")
  local n=${#sorted[@]}
  if (( n == 0 )); then echo 0; return; fi
  if (( n % 2 == 1 )); then
    echo "${sorted[$((n/2))]}"
  else
    echo $(( (sorted[$((n/2 - 1))] + sorted[$((n/2))]) / 2 ))
  fi
}

# Compute p90 from sorted array (passed as args)
compute_p90() {
  local -a sorted=("$@")
  local n=${#sorted[@]}
  if (( n == 0 )); then echo 0; return; fi
  local idx=$(( (n * 90 + 99) / 100 - 1 ))
  if (( idx >= n )); then idx=$((n - 1)); fi
  echo "${sorted[$idx]}"
}

# --- preflight ---

echo "== latency-envelope-measure: N=$N host=$HOST port=$PORT =="

# Check health
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${BASE}/api/health" 2>/dev/null || echo "000")
if [[ "$http_code" != "200" ]]; then
  echo "FAIL: web server not reachable at ${BASE}/api/health (HTTP $http_code)"
  echo "Start the web server first: ./run-web.sh"
  exit 1
fi

MODEL=$(get_model_info)
LIGHT_CTX="${CHUMP_LIGHT_CONTEXT:-0}"
echo "Model: $MODEL | CHUMP_LIGHT_CONTEXT=$LIGHT_CTX"

# Create a session for the test
SESSION_ID=$(create_session)
if [[ -z "$SESSION_ID" ]]; then
  echo "FAIL: could not create session"
  exit 1
fi
echo "Session: $SESSION_ID"

# Warmup turn (discard)
echo "Warming up model..."
measure_turn "Hello" "$SESSION_ID" >/dev/null 2>&1 || true

# --- Scenario A: no-tool chat ---
echo ""
echo "--- Scenario A: no-tool chat (N=$N) ---"
declare -a times_a=()
for i in $(seq 1 "$N"); do
  ms=$(measure_turn "$PROMPT_A" "$SESSION_ID")
  times_a+=("$ms")
  secs=$(echo "scale=2; $ms / 1000" | bc 2>/dev/null || echo "$ms ms")
  echo "  Run $i: ${secs}s"
  printf '{"scenario":"A","run":%d,"ms":%d,"model":"%s","date":"%s"}\n' "$i" "$ms" "$MODEL" "$DATE_UTC" >> "$LOG"
done

# Sort for stats
IFS=$'\n' sorted_a=($(printf '%s\n' "${times_a[@]}" | sort -n)); unset IFS
median_a_ms=$(compute_median "${sorted_a[@]}")
p90_a_ms=$(compute_p90 "${sorted_a[@]}")
median_a=$(echo "scale=1; $median_a_ms / 1000" | bc 2>/dev/null || echo "$median_a_ms")
p90_a=$(echo "scale=1; $p90_a_ms / 1000" | bc 2>/dev/null || echo "$p90_a_ms")
echo "Scenario A: median=${median_a}s  p90=${p90_a}s"

# --- Scenario B: 3-tool sequence ---
echo ""
echo "--- Scenario B: 3-tool sequence (N=$N) ---"
declare -a times_b=()
for i in $(seq 1 "$N"); do
  ms=$(measure_turn "$PROMPT_B" "$SESSION_ID")
  times_b+=("$ms")
  secs=$(echo "scale=2; $ms / 1000" | bc 2>/dev/null || echo "$ms ms")
  echo "  Run $i: ${secs}s"
  printf '{"scenario":"B","run":%d,"ms":%d,"model":"%s","date":"%s"}\n' "$i" "$ms" "$MODEL" "$DATE_UTC" >> "$LOG"
done

IFS=$'\n' sorted_b=($(printf '%s\n' "${times_b[@]}" | sort -n)); unset IFS
median_b_ms=$(compute_median "${sorted_b[@]}")
p90_b_ms=$(compute_p90 "${sorted_b[@]}")
median_b=$(echo "scale=1; $median_b_ms / 1000" | bc 2>/dev/null || echo "$median_b_ms")
p90_b=$(echo "scale=1; $p90_b_ms / 1000" | bc 2>/dev/null || echo "$p90_b_ms")
echo "Scenario B: median=${median_b}s  p90=${p90_b}s"

# --- Append to doc ---
echo "" >> "$DOC"
echo "| $DATE_UTC | $OPERATOR | $MODEL | A | $N | ${median_a} | ${p90_a} | $LIGHT_CTX | auto-measured |" >> "$DOC"
echo "| | | | B (3-tool) | $N | ${median_b} | ${p90_b} | | |" >> "$DOC"
echo ""
echo "Results appended to $DOC and $LOG"

# --- Summary JSONL ---
printf '{"summary":true,"date":"%s","model":"%s","scenario_a":{"median_ms":%d,"p90_ms":%d,"n":%d},"scenario_b":{"median_ms":%d,"p90_ms":%d,"n":%d}}\n' \
  "$DATE_UTC" "$MODEL" "$median_a_ms" "$p90_a_ms" "$N" "$median_b_ms" "$p90_b_ms" "$N" >> "$LOG"

# --- Cleanup ---
delete_session "$SESSION_ID"
echo "Done. Session cleaned up."
