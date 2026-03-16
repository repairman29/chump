#!/usr/bin/env bash
# Overnight heartbeat: run Chump in short learning rounds for a set duration (default 8 hours).
# Each round sends a self-improvement prompt; Chump uses web_search (Tavily) and stores learnings in memory.
# Requires: TAVILY_API_KEY in .env. Model: Ollama on 11434 (preflight runs warm-the-ovens if needed).
# For reliable overnight runs, build once: cargo build --release. Script uses target/release/rust-agent when present.
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
[[ "$CHUMP_TEST_CONFIG" == "max_m4" ]] && [[ -f "$ROOT/scripts/env-max_m4.sh" ]] && source "$ROOT/scripts/env-max_m4.sh"

if [[ -z "${TAVILY_API_KEY:-}" ]] || [[ "${TAVILY_API_KEY}" == "your-tavily-api-key" ]]; then
  echo "TAVILY_API_KEY is not set or is placeholder. Add it to .env (get a key at tavily.com)." >&2
  exit 1
fi

# Default to Ollama only when OPENAI_API_BASE not set (max_m4 keeps 8000 from env-max_m4.sh).
if [[ -z "${OPENAI_API_BASE:-}" ]]; then
  export OPENAI_API_BASE="http://localhost:11434/v1"
  export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
fi
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"

# Quick test: 2 rounds, 15s interval, ~90s total (for validation without overnight run)
if [[ -n "${HEARTBEAT_QUICK_TEST:-}" ]]; then
  DURATION="${HEARTBEAT_DURATION:-2m}"
  INTERVAL="${HEARTBEAT_INTERVAL:-15s}"
else
  DURATION="${HEARTBEAT_DURATION:-8h}"
  # When cascade is enabled, cloud providers absorb load — use fast 5m interval.
  # Local-only (8000/vLLM-MLX): throttle to 60m. Local-only (Ollama): 45m.
  if [[ "${CHUMP_CASCADE_ENABLED:-0}" == "1" ]]; then
    INTERVAL="${HEARTBEAT_INTERVAL:-5m}"
  elif [[ "${OPENAI_API_BASE:-}" == *":8000"* ]]; then
    INTERVAL="${HEARTBEAT_INTERVAL:-60m}"
  else
    INTERVAL="${HEARTBEAT_INTERVAL:-45m}"
  fi
fi

# Convert DURATION and INTERVAL to seconds for the loop
duration_sec() {
  local v=$1
  if [[ "$v" =~ ^([0-9]+)h$ ]]; then
    echo $((${BASH_REMATCH[1]} * 3600))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then
    echo $((${BASH_REMATCH[1]} * 60))
  elif [[ "$v" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo 3600
  fi
}
DURATION_SEC=$(duration_sec "$DURATION")
INTERVAL_SEC=$(duration_sec "$INTERVAL")

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/heartbeat-learn.log"

# Preflight: 8000 (vLLM-MLX) or 11434 (Ollama).
model_ready_8000() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:8000/v1/models" 2>/dev/null || true
}
ollama_ready() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true
}

if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]]; then
  if [[ "$(model_ready_8000)" == "200" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: model (8000) ready." >> "$LOG"
  else
    echo "Model server not reachable on 8000. Start vLLM-MLX: ./serve-vllm-mlx.sh" >&2
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight failed: 8000 not ready." >> "$LOG"
    exit 1
  fi
else
  if [[ "$(ollama_ready)" == "200" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: Ollama (11434) ready." >> "$LOG"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: Ollama down, attempting warm..." >> "$LOG"
    "$ROOT/scripts/warm-the-ovens.sh" >> "$LOG" 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      sleep 5
      if [[ "$(ollama_ready)" == "200" ]]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: Ollama (11434) ready after warm." >> "$LOG"
        break
      fi
    done
  fi
  if [[ "$(ollama_ready)" != "200" ]]; then
    echo "Ollama not reachable on 11434. Start with: ollama serve" >&2
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight failed: no Ollama." >> "$LOG"
    exit 1
  fi
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

# Optional lock when on 8000 so only one agent round at a time (reduces OOM). HEARTBEAT_LOCK=0 to disable.
[[ -f "$ROOT/scripts/heartbeat-lock.sh" ]] && source "$ROOT/scripts/heartbeat-lock.sh"
use_heartbeat_lock=0
[[ "${HEARTBEAT_LOCK:-1}" == "1" ]] && [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && use_heartbeat_lock=1

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
  round_type="learn"

  # Check for due scheduled items first (--chump-due prints prompt and marks fired)
  DUE_PROMPT=""
  if [[ -x "$ROOT/target/release/rust-agent" ]]; then
    DUE_PROMPT=$(env "OPENAI_API_BASE=$OPENAI_API_BASE" "$ROOT/target/release/rust-agent" --chump-due 2>/dev/null || true)
  fi
  if [[ -n "$DUE_PROMPT" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: running due scheduled item" >> "$LOG"
    prompt="$DUE_PROMPT"
  else
    prompt="${PROMPTS[$idx]}"
  fi

  if [[ "$use_heartbeat_lock" == "1" ]] && ! acquire_heartbeat_lock 120; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: skipped (lock timeout — another round or Discord using model)" >> "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  export CHUMP_HEARTBEAT_ROUND="$round"
  export CHUMP_HEARTBEAT_TYPE="${round_type:-learn}"
  export CHUMP_CURRENT_ROUND_TYPE="${round_type:-learn}"
  export CHUMP_HEARTBEAT_ELAPSED="$elapsed"
  export CHUMP_HEARTBEAT_DURATION="$DURATION_SEC"

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: starting" >> "$LOG"
  if [[ -x "$ROOT/target/release/rust-agent" ]]; then
    RUN_CMD=(env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "CHUMP_HOME=$ROOT" "$ROOT/target/release/rust-agent" --chump "$prompt")
  else
    RUN_CMD=(env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "CHUMP_HOME=$ROOT" "$ROOT/run-local.sh" --chump "$prompt")
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

  [[ "$use_heartbeat_lock" == "1" ]] && release_heartbeat_lock

  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat finished after $round rounds." >> "$LOG"
    break
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping $INTERVAL until next round..." >> "$LOG"
  sleep "$INTERVAL_SEC"
done

echo "Heartbeat learn done. Log: $LOG"
