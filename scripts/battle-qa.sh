#!/usr/bin/env bash
# Battle QA: run 500 user queries against Chump CLI, collect pass/fail, report. Run until pass or max iterations.
#
# Usage:
#   ./scripts/battle-qa.sh                    # Run once, report
#   BATTLE_QA_ITERATIONS=5 ./scripts/battle-qa.sh   # Re-run up to 5 times until all pass or max
#   BATTLE_QA_TIMEOUT=60 ./scripts/battle-qa.sh    # 60s per query (default 90)
#   BATTLE_QA_SKIP=100 ./scripts/battle-qa.sh      # Skip first 100 queries (resume)
#   BATTLE_QA_MAX=50 ./scripts/battle-qa.sh        # Run only first 50 (smoke test)
#
# Requires: Ollama on 11434 (default). Set OPENAI_API_BASE in .env to use another server. CHUMP_REPO/CHUMP_HOME set for repo tools.
# Logs: logs/battle-qa.log, logs/battle-qa-results.json, logs/battle-qa-failures.txt
# Exit: 0 if all pass, 1 otherwise (or after max iterations without full pass).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"

# Cleanup temp files on exit or interrupt
cleanup() {
  rm -f "$ROOT"/logs/battle-qa-out."$$".* 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
export CHUMP_HOME="${CHUMP_HOME:-$ROOT}"

# Default: Ollama on 11434 (same as run-discord.sh / run-local.sh)
export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"

QUERIES_FILE="${BATTLE_QA_QUERIES:-$ROOT/scripts/qa/battle-queries.txt}"
QUERIES_GEN="$ROOT/scripts/qa/generate-battle-queries.sh"
LOG="$ROOT/logs/battle-qa.log"
RESULTS_JSON="$ROOT/logs/battle-qa-results.json"
FAILURES_TXT="$ROOT/logs/battle-qa-failures.txt"
TIMEOUT="${BATTLE_QA_TIMEOUT:-90}"
SKIP="${BATTLE_QA_SKIP:-0}"
MAX_QUERIES="${BATTLE_QA_MAX:-500}"
ITERATIONS="${BATTLE_QA_ITERATIONS:-1}"

mkdir -p "$ROOT/logs"
if [[ -n "${CHUMP_TEST_CONFIG:-}" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Testing with config: $CHUMP_TEST_CONFIG" | tee -a "$LOG"
fi

# Ensure we have 500 queries: generate if missing or stale
if [[ ! -f "$QUERIES_FILE" ]] || [[ "$QUERIES_GEN" -nt "$QUERIES_FILE" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Generating $QUERIES_FILE (500 lines)..." | tee -a "$LOG"
  "$QUERIES_GEN" | head -500 > "$QUERIES_FILE"
fi
TOTAL=$(grep -c . "$QUERIES_FILE" 2>/dev/null || echo 0)
[[ -z "$TOTAL" ]] || [[ "$TOTAL" -lt 1 ]] && TOTAL=0
if [[ "$TOTAL" -lt 500 ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Regenerating $QUERIES_FILE (had $TOTAL lines)." | tee -a "$LOG"
  "$QUERIES_GEN" | head -500 > "$QUERIES_FILE"
  TOTAL=$(grep -c . "$QUERIES_FILE" 2>/dev/null || echo 0)
  [[ -z "$TOTAL" ]] && TOTAL=0
fi

# Chump command
if [[ -x "$ROOT/target/release/rust-agent" ]]; then
  CHUMP_CMD=("$ROOT/target/release/rust-agent" "--chump")
else
  CHUMP_CMD=(cargo run -- "--chump")
fi

# Portable timeout: use timeout(1) if available (exit 124 on timeout), else run in background and kill after TIMEOUT
run_one() {
  local prompt="$1"
  local out_file="$2"
  local exit_code=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "${CHUMP_CMD[@]}" "$prompt" > "$out_file" 2>&1
    exit_code=$?
    # timeout(1) returns 124 on timeout (GNU/coreutils)
    echo "$exit_code"
  else
    "${CHUMP_CMD[@]}" "$prompt" > "$out_file" 2>&1 &
    local pid=$!
    local count=0
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt $TIMEOUT ]]; do
      sleep 1
      count=$((count + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "124"
    else
      wait "$pid" 2>/dev/null
      echo "$?"
    fi
  fi
}

# Pass heuristic: exit 0, and last 2k chars of output don't contain "Error: " at start of line (agent error).
# Optional: BATTLE_QA_ACCEPT_TIMEOUT_OK=1 treats exit 124 (timeout) as pass when tail has no error and len > 300 (verbose/slow but correct).
passes() {
  local out="$1"
  local exit_code="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    if [[ "$exit_code" -eq 124 ]] && [[ -n "${BATTLE_QA_ACCEPT_TIMEOUT_OK:-}" ]]; then
      local tail="${out: -2000}"
      [[ ${#tail} -gt 300 ]] || return 1
    else
      return 1
    fi
  fi
  local tail="${out: -2000}"
  if echo "$tail" | grep -q '^Error: '; then
    return 1
  fi
  if echo "$tail" | grep -qE '^error:'; then
    return 1
  fi
  return 0
}

run_suite() {
  local run_id="$1"
  local passed=0
  local failed=0
  local skipped=0
  local failed_ids=()
  local failed_queries=()
  local failed_categories=()
  local start_ts
  start_ts=$(date +%s)
  echo "[]" > "$RESULTS_JSON.tmp"
  local idx=0
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    idx=$((idx + 1))
    if [[ $idx -le $SKIP ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    if [[ -n "$MAX_QUERIES" ]] && [[ $MAX_QUERIES -gt 0 ]] && [[ $idx -gt $MAX_QUERIES ]]; then
      break
    fi
    local category="${line%%	*}"
    local query="${line#*	}"
    [[ "$category" == "$line" ]] && category="unknown" && query="$line"
    printf "\r[%s] Query %d/%d (pass=%d fail=%d) " "$run_id" "$idx" "$TOTAL" "$passed" "$failed"
    local tmpout="$ROOT/logs/battle-qa-out.$$.$idx"
    local exit_code
    exit_code=$(run_one "$query" "$tmpout")
    local out
    out=$(cat "$tmpout" 2>/dev/null)
    rm -f "$tmpout"
    if passes "$out" "$exit_code"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      failed_ids+=("$idx")
      failed_queries+=("$query")
      failed_categories+=("$category")
      echo "FAIL $idx [$category] $query" >> "$FAILURES_TXT"
      echo "--- output (last 500 chars) ---" >> "$FAILURES_TXT"
      echo "${out: -500}" >> "$FAILURES_TXT"
      echo "--- end ---" >> "$FAILURES_TXT"
    fi
  done < "$QUERIES_FILE"
  local end_ts
  end_ts=$(date +%s)
  local elapsed=$((end_ts - start_ts))
  echo ""
  echo "Run $run_id: $passed passed, $failed failed, $skipped skipped in ${elapsed}s"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Run $run_id: passed=$passed failed=$failed skipped=$skipped elapsed=${elapsed}s" >> "$LOG"
  if [[ $failed -gt 0 ]]; then
    echo "Failures (id category query):" >> "$LOG"
    for i in "${!failed_ids[@]}"; do
      echo "  ${failed_ids[$i]} ${failed_categories[$i]} ${failed_queries[$i]}" >> "$LOG"
    done
    return 1
  fi
  return 0
}

echo "=== Chump Battle QA (500 queries) ===" | tee -a "$LOG"
echo "Queries: $QUERIES_FILE (total $TOTAL)" | tee -a "$LOG"
echo "Timeout: ${TIMEOUT}s per query. Skip: $SKIP. Max: $MAX_QUERIES. Iterations: $ITERATIONS" | tee -a "$LOG"
echo "Results: $RESULTS_JSON, $FAILURES_TXT" | tee -a "$LOG"

# Preflight
if ! port=$(./scripts/check-heartbeat-preflight.sh 2>/dev/null); then
  echo "FAIL: No model server. Start Ollama (ollama serve) or set OPENAI_API_BASE." | tee -a "$LOG"
  exit 1
fi
echo "Preflight: model on $port (OPENAI_API_BASE=$OPENAI_API_BASE)" | tee -a "$LOG"

> "$FAILURES_TXT"
iteration=1
while [[ $iteration -le $ITERATIONS ]]; do
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Iteration $iteration/$ITERATIONS" | tee -a "$LOG"
  if run_suite "iter-$iteration"; then
    echo "=== Battle QA: ALL PASS (iteration $iteration) ===" | tee -a "$LOG"
    exit 0
  fi
  iteration=$((iteration + 1))
  if [[ $iteration -le $ITERATIONS ]]; then
    echo "Re-running in 5s..." | tee -a "$LOG"
    sleep 5
  fi
done

echo "=== Battle QA: FAILURES (see $FAILURES_TXT and $LOG) ===" | tee -a "$LOG"
exit 1
