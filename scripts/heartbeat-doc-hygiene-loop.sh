#!/usr/bin/env bash
# Run **doc_hygiene** heartbeat rounds until duration expires: LLM edits docs, AGENTS.md, .cursor/rules;
# runs doc-keeper for verification. Complements **doc-keeper.sh** (read-only lint).
#
# Shared prompt: scripts/doc-hygiene-round-prompt.bash (same as heartbeat-self-improve.sh doc_hygiene rounds).
#
# Usage:
#   ./scripts/heartbeat-doc-hygiene-loop.sh
#   HEARTBEAT_DURATION=2h HEARTBEAT_INTERVAL=15m ./scripts/heartbeat-doc-hygiene-loop.sh
#   HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-doc-hygiene-loop.sh
#
# Pause: touch logs/pause  or CHUMP_PAUSED=1

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

if [[ -z "${OPENAI_API_BASE:-}" ]]; then
  export OPENAI_API_BASE="http://localhost:11434/v1"
  export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
fi
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"

export CHUMP_CLI_TIMEOUT_SECS="${CHUMP_CLI_TIMEOUT_SECS:-120}"

if [[ -n "${HEARTBEAT_QUICK_TEST:-}" ]]; then
  DURATION="${HEARTBEAT_DURATION:-2m}"
  INTERVAL="${HEARTBEAT_INTERVAL:-30s}"
else
  DURATION="${HEARTBEAT_DURATION:-8h}"
  if [[ "${CHUMP_CASCADE_ENABLED:-0}" == "1" ]]; then
    INTERVAL="${HEARTBEAT_INTERVAL:-5m}"
  elif [[ "${OPENAI_API_BASE:-}" == *":8000"* ]]; then
    INTERVAL="${HEARTBEAT_INTERVAL:-15m}"
  else
    INTERVAL="${HEARTBEAT_INTERVAL:-8m}"
  fi
fi

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
LOG="$ROOT/logs/heartbeat-doc-hygiene-loop.log"

ollama_ready() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true
}
model_ready_8000() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:8000/v1/models" 2>/dev/null || true
}

if [[ -n "${CHUMP_CLOUD_ONLY:-}" ]] && [[ "$CHUMP_CLOUD_ONLY" == "1" ]]; then
  unset -v OPENAI_API_BASE
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Cloud-only: skipping local model preflight." >> "$LOG"
elif [[ "${OPENAI_API_BASE:-}" == *":8000"* ]]; then
  if [[ "$(model_ready_8000)" != "200" ]]; then
    echo "Model server not reachable on 8000." >&2
    exit 1
  fi
else
  if [[ "$(ollama_ready)" == "200" ]]; then
    export OPENAI_API_BASE="http://localhost:11434/v1"
  else
    echo "Ollama not reachable on 11434. Start with: ollama serve" >&2
    exit 1
  fi
fi

# shellcheck source=doc-hygiene-round-prompt.bash
source "$ROOT/scripts/doc-hygiene-round-prompt.bash"
PROMPT=$(doc_hygiene_prompt)

[[ -f "$ROOT/scripts/heartbeat-lock.sh" ]] && source "$ROOT/scripts/heartbeat-lock.sh"
use_heartbeat_lock=0
[[ "${HEARTBEAT_LOCK:-1}" == "1" ]] && [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && use_heartbeat_lock=1

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] doc-hygiene loop started: duration=$DURATION, interval=$INTERVAL" >> "$LOG"

start_ts=$(date +%s)
round=0

while true; do
  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] doc-hygiene loop finished after $round rounds." >> "$LOG"
    break
  fi

  if [[ -f "$ROOT/logs/pause" ]] || [[ "${CHUMP_PAUSED:-0}" == "1" ]] || [[ "${CHUMP_PAUSED:-}" == "true" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round skipped (paused)." >> "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  if [[ "$use_heartbeat_lock" == "1" ]] && ! acquire_heartbeat_lock 120; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round skipped (lock timeout)." >> "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  round=$((round + 1))
  export CHUMP_HEARTBEAT_ROUND="$round"
  export CHUMP_HEARTBEAT_TYPE="doc_hygiene"
  export CHUMP_CURRENT_ROUND_TYPE="doc_hygiene"
  export CHUMP_HEARTBEAT_ELAPSED="$elapsed"
  export CHUMP_HEARTBEAT_DURATION="$DURATION_SEC"
  export CHUMP_ROUND_PRIVACY=safe

  BRAIN_DIR="${CHUMP_BRAIN_PATH:-$ROOT/chump-brain}"
  if [[ -d "$BRAIN_DIR/.git" ]]; then
    git -C "$BRAIN_DIR" pull --rebase >> "$LOG" 2>&1 || true
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: starting doc_hygiene" >> "$LOG"
  if [[ -x "$ROOT/target/release/chump" ]]; then
    RUN_CMD=(env "OPENAI_API_BASE=${OPENAI_API_BASE:-}" "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "$ROOT/target/release/chump" --chump "$PROMPT")
  else
    RUN_CMD=(env "OPENAI_API_BASE=${OPENAI_API_BASE:-}" "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "$ROOT/run-local.sh" --chump "$PROMPT")
  fi
  if "${RUN_CMD[@]}" >> "$LOG" 2>&1; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: ok" >> "$LOG"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: exit non-zero" >> "$LOG"
  fi

  [[ "$use_heartbeat_lock" == "1" ]] && release_heartbeat_lock

  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    break
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping $INTERVAL until next round..." >> "$LOG"
  sleep "$INTERVAL_SEC"
done

echo "Doc-hygiene loop done. Log: $LOG"
