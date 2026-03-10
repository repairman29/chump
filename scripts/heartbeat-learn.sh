#!/usr/bin/env bash
# Overnight heartbeat: run Chump in short learning rounds for a set duration (default 8 hours).
# Each round sends a self-improvement prompt; Chump uses web_search (Tavily) and stores learnings in memory.
# Requires: TAVILY_API_KEY in .env. Preflight picks a model server: 8000 if up, else starts/restarts 8000 via warm-the-ovens, then falls back to 8001 if 8000 stays down.
# For reliable overnight runs, build once first: cargo build --release. The script then uses target/release/rust-agent and avoids cargo run (no recompile or sandbox build failures).
#
# Usage:
#   ./scripts/heartbeat-learn.sh                    # 8h, round every 45 min
#   HEARTBEAT_DURATION=4h HEARTBEAT_INTERVAL=30m ./scripts/heartbeat-learn.sh
#   HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-learn.sh   # 2m, 15s interval (quick validation)
#   HEARTBEAT_RETRY=1 ./scripts/heartbeat-learn.sh        # retry once per round on failure
#
# Logs: logs/heartbeat-learn.log (append). Do not commit TAVILY_API_KEY; set it in .env only.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

if [[ -z "${TAVILY_API_KEY:-}" ]] || [[ "${TAVILY_API_KEY}" == "your-tavily-api-key" ]]; then
  echo "TAVILY_API_KEY is not set or is placeholder. Add it to .env (get a key at tavily.com)." >&2
  exit 1
fi

export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:8000/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-default}"

# Quick test: 2 rounds, 15s interval, ~90s total (for validation without overnight run)
if [[ -n "${HEARTBEAT_QUICK_TEST:-}" ]]; then
  DURATION="${HEARTBEAT_DURATION:-2m}"
  INTERVAL="${HEARTBEAT_INTERVAL:-15s}"
else
  # Duration to run (default 8h). Examples: 8h, 4h, 30m
  DURATION="${HEARTBEAT_DURATION:-8h}"
  # Time between rounds (default 45 min). Examples: 45m, 30m, 1h
  INTERVAL="${HEARTBEAT_INTERVAL:-45m}"
fi

# Convert DURATION and INTERVAL to seconds for the loop
duration_sec() {
  local v=$1
  if [[ "$v" =~ ^([0-9]+)h$ ]]; then
    echo $((${BASH_REMATCH[1]} * 3600))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then
    echo $((${BASH_REMATCH[1]} * 60))
  else
    echo 3600
  fi
}
DURATION_SEC=$(duration_sec "$DURATION")
INTERVAL_SEC=$(duration_sec "$INTERVAL")

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/heartbeat-learn.log"

# Preflight: ensure a model server is reachable. Prefer 8000; if down, try to start it, then fall back to 8001.
model_ready() {
  local port=$1
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${port}/v1/models" 2>/dev/null || true
}

CHOSEN_PORT=""
if [[ "$(model_ready 8000)" == "200" ]]; then
  CHOSEN_PORT=8000
  export OPENAI_API_BASE="http://localhost:8000/v1"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: port 8000 ready." >> "$LOG"
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: 8000 down, attempting to start/restart..." >> "$LOG"
  "$ROOT/scripts/warm-the-ovens.sh" >> "$LOG" 2>&1 || true
  # Re-check 8000 after a short wait
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 5
    if [[ "$(model_ready 8000)" == "200" ]]; then
      CHOSEN_PORT=8000
      export OPENAI_API_BASE="http://localhost:8000/v1"
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: port 8000 ready after warm." >> "$LOG"
      break
    fi
  done
  if [[ -z "$CHOSEN_PORT" ]] && [[ "$(model_ready 8001)" == "200" ]]; then
    CHOSEN_PORT=8001
    export OPENAI_API_BASE="http://localhost:8001/v1"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: using fallback port 8001." >> "$LOG"
  fi
fi

if [[ -z "$CHOSEN_PORT" ]]; then
  echo "No model server on 8000 or 8001. Start vLLM (e.g. scripts/warm-the-ovens.sh or scripts/serve-vllm-mlx.sh) and retry." >&2
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight failed: no server on 8000 or 8001." >> "$LOG"
  exit 1
fi

# Optional: warm the ovens once at start so 8000 (and optionally 8001) are up (legacy; preflight above handles 8000/8001)
if [[ -n "${CHUMP_WARM_SERVERS:-}" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Warming servers..." >> "$LOG"
  "$ROOT/scripts/warm-the-ovens.sh" >> "$LOG" 2>&1 || true
fi

# Self-improvement prompts: research a topic, then store learnings in memory. Rotate through.
PROMPTS=(
  "This is a self-improvement round. Use web_search with one or two focused queries to research: Rust async best practices and common pitfalls. Store the most useful facts and patterns in memory for future use. Be concise."
  "This is a self-improvement round. Use web_search to research: recent advances in LLM agents and tool use (last year). Store 3–5 key learnings in memory. Be concise."
  "This is a self-improvement round. Use web_search to research: macOS launchd and cron for scheduling tasks. Store useful facts in memory. Be concise."
  "This is a self-improvement round. Use web_search to research: effective debugging strategies for distributed or async systems. Store learnings in memory. Be concise."
  "This is a self-improvement round. Use web_search to research: best practices for Discord bot design and rate limits. Store key points in memory. Be concise."
  "This is a self-improvement round. Use web_search to research: prompt engineering for tool-using agents. Store 3–5 practical tips in memory. Be concise."
  "This is a self-improvement round. Use web_search to research: semantic memory and embeddings for chatbots. Store useful concepts in memory. Be concise."
  "This is a self-improvement round. Use web_search to research: security best practices for local AI agents (API keys, sandboxing). Store learnings in memory. Be concise."
)

start_ts=$(date +%s)
round=0

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat started: duration=$DURATION, interval=$INTERVAL" >> "$LOG"

while true; do
  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat finished after $round rounds." >> "$LOG"
    break
  fi

  # Kill switch: skip this round if Chump is paused
  if [[ -f "$ROOT/logs/pause" ]] || [[ "${CHUMP_PAUSED:-0}" == "1" ]] || [[ "${CHUMP_PAUSED:-}" == "true" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round skipped (paused: remove logs/pause or unset CHUMP_PAUSED)" >> "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  round=$((round + 1))
  idx=$(( (round - 1) % ${#PROMPTS[@]} ))
  prompt="${PROMPTS[$idx]}"

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: starting" >> "$LOG"
  if [[ -x "$ROOT/target/release/rust-agent" ]]; then
    RUN_CMD=("$ROOT/target/release/rust-agent" --chump "$prompt")
  else
    RUN_CMD=(./run-best.sh --chump "$prompt")
  fi
  if "${RUN_CMD[@]}" >> "$LOG" 2>&1; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: ok" >> "$LOG"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: exit non-zero" >> "$LOG"
    # Optional: retry once (transient connection/model errors)
    if [[ -n "${HEARTBEAT_RETRY:-}" ]]; then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: retry" >> "$LOG"
      if "${RUN_CMD[@]}" >> "$LOG" 2>&1; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: ok (after retry)" >> "$LOG"
      else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: retry failed" >> "$LOG"
      fi
    fi
  fi

  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat finished after $round rounds." >> "$LOG"
    break
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping $INTERVAL until next round..." >> "$LOG"
  sleep "$INTERVAL_SEC"
done

echo "Heartbeat done. Log: $LOG"
