#!/usr/bin/env bash
# Run Chump autonomy tier tests. Pass all to "release" full autonomy (see docs/CHUMP_AUTONOMY_TESTS.md).
# From rust-agent: ./scripts/run-autonomy-tests.sh
# Optional: AUTONOMY_TIER_MIN=2 to run only tiers 0-2 (skip Tavily/sustain).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:8000/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-default}"

mkdir -p "$ROOT/logs"
TIER_FILE="$ROOT/logs/autonomy-tier.env"
MAX_TIER=4
MIN_TIER="${AUTONOMY_TIER_MIN:-0}"
PASSED_TIER=-1

# Chump command: release binary if present, else cargo run
if [[ -x "$ROOT/target/release/rust-agent" ]]; then
  CHUMP_CMD=("$ROOT/target/release/rust-agent" "--chump")
else
  CHUMP_CMD=(cargo run -- "--chump")
fi

run_chump() {
  local prompt="$1"
  if [[ -x "$ROOT/target/release/rust-agent" ]]; then
    "${CHUMP_CMD[@]}" "$prompt" 2>&1
  else
    (cd "$ROOT" && "${CHUMP_CMD[@]}" "$prompt") 2>&1
  fi
}

echo "=== Chump autonomy tests (tiers $MIN_TIER–$MAX_TIER) ==="

# Tier 0: preflight
echo -n "Tier 0 (baseline): "
if port=$(./scripts/check-heartbeat-preflight.sh 2>/dev/null); then
  echo "PASS (model on $port)"
  PASSED_TIER=0
else
  echo "FAIL (no model on 8000 or 8001)"
  echo "CHUMP_AUTONOMY_TIER=-1" > "$TIER_FILE"
  exit 1
fi

[[ $MIN_TIER -gt 0 ]] && echo "Stopping at tier min $MIN_TIER" && echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE" && exit 0

# Tier 1a: calculator
echo -n "Tier 1a (calculator): "
out=$(run_chump "What is 13 times 7? Reply with only the number." 2>/dev/null) || true
if echo "$out" | grep -qE '\b91\b|calculator|run_cli'; then
  echo "PASS"
  PASSED_TIER=1
else
  echo "FAIL (no 91 or calculator in output)"
  echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
  exit 1
fi

# Tier 1b: memory store
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
echo -n "Tier 4 (sustain): "
if [[ -z "${TAVILY_API_KEY:-}" ]] || [[ "${TAVILY_API_KEY}" == "your-tavily-api-key" ]]; then
  echo "SKIP (TAVILY_API_KEY not set)"
else
  ./scripts/test-heartbeat-learn.sh 2>&1 | tee -a "$ROOT/logs/autonomy-tier4.log"; tier4_exit=${PIPESTATUS[0]}
  if [[ $tier4_exit -eq 0 ]]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8000/v1/models 2>/dev/null) || true
    if [[ "$code" == "200" ]]; then
      echo "PASS (heartbeat + server still up)"
      PASSED_TIER=4
    else
      echo "FAIL (server not responding after heartbeat)"
      echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
      exit 1
    fi
  else
    echo "FAIL (heartbeat smoke test exited non-zero)"
    echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
    exit 1
  fi
fi

echo "CHUMP_AUTONOMY_TIER=$PASSED_TIER" > "$TIER_FILE"
echo "=== All tiers passed. Autonomy tier: $PASSED_TIER (released). State: $TIER_FILE ==="
exit 0
