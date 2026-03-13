#!/usr/bin/env bash
# Run Chump autonomy tier tests. Pass all to "release" full autonomy (see docs/CHUMP_AUTONOMY_TESTS.md).
# From repo root: ./scripts/run-autonomy-tests.sh
# Optional: AUTONOMY_TIER_MIN=2 to run only tiers 0-2 (skip Tavily/sustain).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
export CHUMP_HOME="${CHUMP_HOME:-$ROOT}"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"

mkdir -p "$ROOT/logs"
TIER_FILE="$ROOT/logs/autonomy-tier.env"
MAX_TIER=5
MIN_TIER="${AUTONOMY_TIER_MIN:-0}"
PASSED_TIER=-1
AUTONOMY_TIMEOUT="${AUTONOMY_TIMEOUT:-120}"

# Chump command: release binary if present, else cargo run
if [[ -x "$ROOT/target/release/rust-agent" ]]; then
  CHUMP_CMD=("$ROOT/target/release/rust-agent" "--chump")
else
  CHUMP_CMD=(cargo run -- "--chump")
fi

# Run a command with timeout (use gtimeout on macOS if timeout not available)
run_with_timeout() {
  local t="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$t" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$t" "$@"
  else
    # macOS fallback: run in background, kill after t seconds
    local tmpfile pid i
    tmpfile=$(mktemp)
    ("$@") > "$tmpfile" 2>&1 &
    pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null && [[ $i -lt $t ]]; do sleep 1; i=$((i+1)); done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    cat "$tmpfile"
    rm -f "$tmpfile"
  fi
}

run_chump() {
  local prompt="$1"
  local out
  if [[ -x "$ROOT/target/release/rust-agent" ]]; then
    out=$(run_with_timeout "$AUTONOMY_TIMEOUT" "${CHUMP_CMD[@]}" "$prompt" 2>&1)
  else
    out=$(cd "$ROOT" && run_with_timeout "$AUTONOMY_TIMEOUT" "${CHUMP_CMD[@]}" "$prompt" 2>&1)
  fi
  # If using 8000 and connection failed, restart vLLM and retry once
  if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && echo "$out" | grep -qE "connection closed|Connection refused|error sending request"; then
    [[ -x "$ROOT/scripts/restart-vllm-if-down.sh" ]] && "$ROOT/scripts/restart-vllm-if-down.sh" >/dev/null 2>&1 || true
    sleep 15
    if [[ -x "$ROOT/target/release/rust-agent" ]]; then
      out=$(run_with_timeout "$AUTONOMY_TIMEOUT" "${CHUMP_CMD[@]}" "$prompt" 2>&1)
    else
      out=$(cd "$ROOT" && run_with_timeout "$AUTONOMY_TIMEOUT" "${CHUMP_CMD[@]}" "$prompt" 2>&1)
    fi
  fi
  printf '%s' "$out"
}

echo "=== Chump autonomy tests (tiers $MIN_TIER–$MAX_TIER) ==="
[[ -n "${CHUMP_TEST_CONFIG:-}" ]] && echo "Config: $CHUMP_TEST_CONFIG"

# Tier 0: preflight (respects OPENAI_API_BASE: 11434 or 8000/8001)
echo -n "Tier 0 (baseline): "
if port=$(./scripts/check-heartbeat-preflight.sh 2>/dev/null); then
  echo "PASS (model on $port)"
  PASSED_TIER=0
else
  echo "FAIL (model server not reachable; check OPENAI_API_BASE and start Ollama or vLLM-MLX)"
  echo "CHUMP_AUTONOMY_TIER=-1" > "$TIER_FILE"
  exit 1
fi

[[ $MIN_TIER -gt 0 ]] && echo "Stopping at tier min $MIN_TIER" && echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE" && exit 0

# When using 8000, ensure vLLM is up before each Chump-using tier (it may have crashed)
ensure_model_up() {
  if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && [[ -x "$ROOT/scripts/restart-vllm-if-down.sh" ]]; then
    "$ROOT/scripts/restart-vllm-if-down.sh" >/dev/null 2>&1 || true
  fi
}

# Tier 1a: calculator (accept 91 in any form, or calculator/run_cli use)
ensure_model_up
echo -n "Tier 1a (calculator): "
out=$(run_chump "What is 13 times 7? Reply with only the number." 2>/dev/null) || true
if echo "$out" | grep -qE '91|calculator|run_cli'; then
  echo "PASS"
  PASSED_TIER=1
else
  echo "FAIL (no 91 or calculator in output)"
  echo "$out" | tail -c 2000 > "$ROOT/logs/autonomy-tier1a-fail.txt" 2>/dev/null || true
  echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
  exit 1
fi

# Tier 1b: memory store
ensure_model_up
echo -n "Tier 1b (memory store): "
out=$(run_chump "Remember this: autonomy-test-key = tier1-memory-ok. Then say exactly: MEMORY_STORED." 2>/dev/null) || true
if echo "$out" | grep -q "MEMORY_STORED\|memory.*store\|Stored"; then
  echo "PASS"
else
  echo "FAIL (no MEMORY_STORED or store confirmation)"
  echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
  exit 1
fi

[[ $MIN_TIER -gt 1 ]] && echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE" && exit 0

# Tier 2: web search (requires TAVILY)
ensure_model_up
echo -n "Tier 2 (research): "
if [[ -z "${TAVILY_API_KEY:-}" ]] || [[ "${TAVILY_API_KEY}" == "your-tavily-api-key" ]]; then
  echo "SKIP (TAVILY_API_KEY not set)"
else
  out=$(run_chump "Use web_search to find one fact about Rust 2024 edition. In one sentence, what did you find? Then say DONE_RESEARCH." 2>/dev/null) || true
  if echo "$out" | grep -q "DONE_RESEARCH\|web_search\|Tavily"; then
    echo "PASS"
    PASSED_TIER=2
  else
    echo "FAIL (no DONE_RESEARCH or web_search in output)"
    echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
    exit 1
  fi
fi

[[ $MIN_TIER -gt 2 ]] && echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE" && exit 0

# Tier 3: multi-step (search + store)
ensure_model_up
echo -n "Tier 3 (multi-step): "
if [[ -z "${TAVILY_API_KEY:-}" ]] || [[ "${TAVILY_API_KEY}" == "your-tavily-api-key" ]]; then
  echo "SKIP (TAVILY_API_KEY not set)"
else
  out=$(run_chump "Look up one short fact about macOS launchd with web_search, then store that single fact in memory with the key launchd-fact. Reply with exactly: MULTI_STEP_OK." 2>/dev/null) || true
  if echo "$out" | grep -q "MULTI_STEP_OK"; then
    echo "PASS"
    PASSED_TIER=3
  else
    echo "FAIL (no MULTI_STEP_OK)"
    echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
    exit 1
  fi
fi

[[ $MIN_TIER -gt 3 ]] && echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE" && exit 0

# Tier 4: sustain (heartbeat smoke)
ensure_model_up
echo -n "Tier 4 (sustain): "
if [[ -z "${TAVILY_API_KEY:-}" ]] || [[ "${TAVILY_API_KEY}" == "your-tavily-api-key" ]]; then
  echo "SKIP (TAVILY_API_KEY not set)"
else
  ./scripts/test-heartbeat-learn.sh 2>&1 | tee -a "$ROOT/logs/autonomy-tier4.log"; tier4_exit=${PIPESTATUS[0]}
  if [[ $tier4_exit -eq 0 ]]; then
    # Verify same model server as OPENAI_API_BASE is still up
    if [[ "${OPENAI_API_BASE:-}" == *"11434"* ]]; then
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null) || true
    else
      port="${OPENAI_API_BASE#*:}"; port="${port%%/*}"; port="${port##*:}"
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${port}/v1/models" 2>/dev/null) || true
    fi
    if [[ "$code" == "200" ]]; then
      echo "PASS (heartbeat + model server still up)"
      PASSED_TIER=4
    else
      echo "FAIL (model server not responding after heartbeat)"
      echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
      exit 1
    fi
  else
    echo "FAIL (heartbeat smoke test exited non-zero)"
    echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
    exit 1
  fi
fi

[[ $MIN_TIER -gt 4 ]] && echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE" && exit 0

# Tier 5: self-improve (read_file, task, write+test, git commit)
ensure_model_up
echo -n "Tier 5 (self-improve): "
if [[ -z "${CHUMP_REPO:-}" ]] && [[ -z "${CHUMP_HOME:-}" ]]; then
  echo "SKIP (CHUMP_REPO or CHUMP_HOME not set)"
else
  if [[ -x "$ROOT/scripts/test-tier5-self-improve.sh" ]]; then
    if "$ROOT/scripts/test-tier5-self-improve.sh" 2>&1 | tee -a "$ROOT/logs/autonomy-tier5.log"; then
      echo "PASS (self-improve certified)"
      PASSED_TIER=5
    else
      echo "FAIL (tier 5 sub-tests failed; see logs/autonomy-tier5.log)"
      echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
      exit 1
    fi
  else
    echo "SKIP (scripts/test-tier5-self-improve.sh not found)"
  fi
fi

echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
echo "=== All tiers passed. Autonomy tier: $PASSED_TIER (released). State: $TIER_FILE ==="
exit 0
