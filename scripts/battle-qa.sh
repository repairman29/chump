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
# Custom BATTLE_QA_QUERIES files are never overwritten; only scripts/qa/battle-queries.txt is auto-generated to 500 lines.
# Requires: Ollama on 11434 (default). Set OPENAI_API_BASE in .env to use another server. CHUMP_REPO/CHUMP_HOME set for repo tools.
# If OPENAI_API_BASE / OPENAI_API_KEY / OPENAI_MODEL are already exported when you invoke this script, they override .env for that run.
# Logs: logs/battle-qa.log, logs/battle-qa-results.json, logs/battle-qa-failures.txt
# Tail alongside web dogfood: ./scripts/tail-model-dogfood.sh (see docs/MODEL_TESTING_TAIL.md)
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

# If the caller already exported OPENAI_*, keep those over .env (explicit one-off / CI run).
_save_openai_base="${OPENAI_API_BASE:-}"
_save_openai_key="${OPENAI_API_KEY:-}"
_save_openai_model="${OPENAI_MODEL:-}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
[[ -n "$_save_openai_base" ]] && export OPENAI_API_BASE="$_save_openai_base"
[[ -n "$_save_openai_key" ]] && export OPENAI_API_KEY="$_save_openai_key"
[[ -n "$_save_openai_model" ]] && export OPENAI_MODEL="$_save_openai_model"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
export CHUMP_HOME="${CHUMP_HOME:-$ROOT}"

# Default: Ollama on 11434 (same as run-discord.sh / run-local.sh)
export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:11434/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"

DEFAULT_QUERIES="$ROOT/scripts/qa/battle-queries.txt"
QUERIES_FILE="${BATTLE_QA_QUERIES:-$DEFAULT_QUERIES}"
QUERIES_GEN="$ROOT/scripts/qa/generate-battle-queries.sh"
LOG="$ROOT/logs/battle-qa.log"
RESULTS_JSON="$ROOT/logs/battle-qa-results.json"
FAILURES_TXT="$ROOT/logs/battle-qa-failures.txt"
TIMEOUT="${BATTLE_QA_TIMEOUT:-90}"
SKIP="${BATTLE_QA_SKIP:-0}"
MAX_QUERIES="${BATTLE_QA_MAX:-500}"
ITERATIONS="${BATTLE_QA_ITERATIONS:-1}"
WITH_JUDGE=0
for arg in "$@"; do
  [[ "$arg" == "--with-judge" ]] && WITH_JUDGE=1
done

# EVAL-006: --with-judge flag wires the LLM-as-judge pass in the Chump binary
# (EVAL-002 + EVAL-004). When set, we export CHUMP_EVAL_WITH_JUDGE=1 for the
# child process and emit a per-EvalCategory average judge score at the end
# of the run. Reads from sessions/chump_eval.db (chump_eval_runs.scores_json)
# which eval_harness writes when cases include an ExpectedProperty::LlmJudge.
#
# EVAL-003: --with-replay runs scripts/replay-trajectory.sh against the saved
# golden trajectories after the main battle-qa loop. Catches multi-turn
# regressions (storming, missing-tool, wrong-tool patterns) that single-turn
# property checks don't see.
WITH_JUDGE=0
WITH_REPLAY=0
for arg in "$@"; do
  case "$arg" in
    --with-judge) WITH_JUDGE=1 ;;
    --with-replay) WITH_REPLAY=1 ;;
    --with-all) WITH_JUDGE=1; WITH_REPLAY=1 ;;
    -h|--help)
      echo "Usage: $0 [--with-judge] [--with-replay] [--with-all]"
      echo "  --with-judge    enable LLM-as-judge scoring; print per-category avg"
      echo "  --with-replay   run golden-trajectory replay after main loop"
      echo "  --with-all      both of the above"
      exit 0
      ;;
  esac
done
if [[ "$WITH_JUDGE" == "1" ]]; then
  export CHUMP_EVAL_WITH_JUDGE=1
fi

# Emit "Avg judge score per category" from chump_eval_runs. No-op unless
# --with-judge was passed AND the DB has at least one judge_score entry.
emit_judge_summary() {
  [[ "$WITH_JUDGE" != "1" ]] && return 0
  local db="$ROOT/sessions/chump_eval.db"
  if [[ ! -f "$db" ]]; then
    echo "[judge] No $db — judge summary skipped (run Chump with CHUMP_EVAL_WITH_JUDGE=1 first)." | tee -a "$LOG"
    return 0
  fi
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "[judge] sqlite3 not installed — cannot emit per-category summary." | tee -a "$LOG"
    return 0
  fi
  # jq extracts the judge_score (optional) from scores_json and joins with
  # chump_eval_cases.category. We use sqlite3's JSON1 operators so jq isn't
  # required on the reader side.
  local rows
  rows=$(sqlite3 -separator $'\t' "$db" <<'SQL' 2>/dev/null
SELECT
  json_extract(c.category, '$') AS category,
  ROUND(AVG(CAST(json_extract(r.scores_json, '$.judge_score') AS REAL)), 3) AS avg_score,
  COUNT(*) AS n
FROM chump_eval_runs r
JOIN chump_eval_cases c ON c.id = r.eval_case_id
WHERE json_extract(r.scores_json, '$.judge_score') IS NOT NULL
GROUP BY json_extract(c.category, '$')
ORDER BY category;
SQL
)
  if [[ -z "$rows" ]]; then
    echo "[judge] Avg judge score per category: (no judged runs in $db)" | tee -a "$LOG"
    return 0
  fi
  {
    echo ""
    echo "=== Avg judge score per category ==="
    printf "%-25s %10s %5s\n" "Category" "Mean" "Runs"
    printf "%-25s %10s %5s\n" "-------------------------" "----------" "-----"
    while IFS=$'\t' read -r cat mean n; do
      printf "%-25s %10s %5s\n" "$cat" "$mean" "$n"
    done <<< "$rows"
  } | tee -a "$LOG"
}

mkdir -p "$ROOT/logs"
if [[ -n "${CHUMP_TEST_CONFIG:-}" ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Testing with config: $CHUMP_TEST_CONFIG" | tee -a "$LOG"
fi

# Only auto-generate/refresh the default 500-line file. Never overwrite BATTLE_QA_QUERIES custom paths.
if [[ "$QUERIES_FILE" == "$DEFAULT_QUERIES" ]]; then
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
else
  if [[ ! -f "$QUERIES_FILE" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: BATTLE_QA_QUERIES file not found: $QUERIES_FILE" | tee -a "$LOG"
    exit 1
  fi
  TOTAL=$(grep -c . "$QUERIES_FILE" 2>/dev/null || echo 0)
  [[ -z "$TOTAL" ]] || [[ "$TOTAL" -lt 1 ]] && TOTAL=0
  if [[ "$TOTAL" -lt 1 ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $QUERIES_FILE has no query lines." | tee -a "$LOG"
    exit 1
  fi
fi

# Chump command (binary name is "chump" per Cargo.toml [[bin]])
if [[ -x "$ROOT/target/release/chump" ]]; then
  CHUMP_CMD=("$ROOT/target/release/chump" "--chump")
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

echo "=== Chump Battle QA ($TOTAL queries in file) ===" | tee -a "$LOG"
echo "Queries: $QUERIES_FILE (total $TOTAL)" | tee -a "$LOG"
echo "Timeout: ${TIMEOUT}s per query. Skip: $SKIP. Max: $MAX_QUERIES. Iterations: $ITERATIONS" | tee -a "$LOG"
echo "Results: $RESULTS_JSON, $FAILURES_TXT" | tee -a "$LOG"

# Preflight
if ! port=$(./scripts/check-heartbeat-preflight.sh 2>/dev/null); then
  echo "FAIL: No model server. Start Ollama (ollama serve) or set OPENAI_API_BASE." | tee -a "$LOG"
  exit 1
fi
echo "Preflight: model on $port (OPENAI_API_BASE=$OPENAI_API_BASE)" | tee -a "$LOG"

report_judge_scores() {
  local db
  db="${CHUMP_DB:-$ROOT/data/chump.db}"
  if [[ ! -f "$db" ]]; then
    db="${CHUMP_DB_PATH:-$ROOT/data/chump.db}"
  fi
  if [[ ! -f "$db" ]] || ! command -v sqlite3 &>/dev/null; then
    return 0
  fi
  # Print average judge_score per category from the last 50 eval runs that have a judge score.
  # scores_json stores EvalScores as JSON; extract judge_score field with JSON1 extension.
  local result
  result=$(sqlite3 "$db" <<'SQL' 2>/dev/null
SELECT
  ec.category,
  printf('%.3f', AVG(CAST(json_extract(er.scores_json, '$.judge_score') AS REAL))) AS avg_judge
FROM chump_eval_runs er
JOIN chump_eval_cases ec ON ec.id = er.eval_case_id
WHERE json_extract(er.scores_json, '$.judge_score') IS NOT NULL
GROUP BY ec.category
ORDER BY ec.category;
SQL
)
  if [[ -n "$result" ]]; then
    echo "" | tee -a "$LOG"
    echo "=== LLM-as-Judge Scores by Category ===" | tee -a "$LOG"
    echo "$result" | while IFS='|' read -r cat score; do
      echo "  $cat: avg_judge=$score" | tee -a "$LOG"
    done
  fi
}

> "$FAILURES_TXT"
iteration=1
while [[ $iteration -le $ITERATIONS ]]; do
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Iteration $iteration/$ITERATIONS" | tee -a "$LOG"
  if run_suite "iter-$iteration"; then
    echo "=== Battle QA: ALL PASS (iteration $iteration) ===" | tee -a "$LOG"
    if [[ -x "$ROOT/scripts/consciousness-baseline.sh" ]]; then
      echo "" | tee -a "$LOG"
      echo "=== Consciousness Metrics (post-battle-QA) ===" | tee -a "$LOG"
      "$ROOT/scripts/consciousness-baseline.sh" 2>&1 | tail -8 | tee -a "$LOG"
      # Rotate baseline for next regression gate comparison
      CURRENT="$ROOT/logs/consciousness-baseline.json"
      [[ -f "$CURRENT" ]] && cp "$CURRENT" "$ROOT/logs/consciousness-baseline-prev.json"
    fi
    emit_judge_summary
    exit 0
  fi
  iteration=$((iteration + 1))
  if [[ $iteration -le $ITERATIONS ]]; then
    echo "Re-running in 5s..." | tee -a "$LOG"
    sleep 5
  fi
done

# Consciousness metrics snapshot after battle QA run
if [[ -x "$ROOT/scripts/consciousness-baseline.sh" ]]; then
  echo "" | tee -a "$LOG"
  echo "=== Consciousness Metrics (post-battle-QA) ===" | tee -a "$LOG"
  "$ROOT/scripts/consciousness-baseline.sh" 2>&1 | tail -8 | tee -a "$LOG"

  # --- Consciousness regression gate ---
  # If a previous baseline exists, compare key metrics and warn on regression.
  CURRENT="$ROOT/logs/consciousness-baseline.json"
  PREV="$ROOT/logs/consciousness-baseline-prev.json"
  if [[ -f "$PREV" ]] && [[ -f "$CURRENT" ]] && command -v jq &>/dev/null; then
    echo "" | tee -a "$LOG"
    echo "=== Consciousness Regression Gate ===" | tee -a "$LOG"
    GATE_FAIL=0

    PREV_MEAN=$(jq -r '.surprise.mean_surprisal // 0' "$PREV")
    CURR_MEAN=$(jq -r '.surprise.mean_surprisal // 0' "$CURRENT")
    # Fail if mean surprisal increased by more than 50%
    if command -v bc &>/dev/null && [[ "$PREV_MEAN" != "0" ]]; then
      RATIO=$(echo "scale=2; $CURR_MEAN / $PREV_MEAN" 2>/dev/null || echo "1")
      if (( $(echo "$RATIO > 1.50" | bc -l 2>/dev/null || echo 0) )); then
        echo "  REGRESSION: mean_surprisal increased from $PREV_MEAN to $CURR_MEAN (ratio: $RATIO)" | tee -a "$LOG"
        GATE_FAIL=1
      else
        echo "  OK: mean_surprisal $PREV_MEAN -> $CURR_MEAN (ratio: $RATIO)" | tee -a "$LOG"
      fi
    fi

    PREV_LESSONS=$(jq -r '.counterfactual.lesson_count // 0' "$PREV")
    CURR_LESSONS=$(jq -r '.counterfactual.lesson_count // 0' "$CURRENT")
    # Warn if lesson count dropped (lessons deleted unexpectedly)
    if [[ "$CURR_LESSONS" -lt "$PREV_LESSONS" ]]; then
      echo "  WARNING: lesson_count dropped from $PREV_LESSONS to $CURR_LESSONS" | tee -a "$LOG"
    else
      echo "  OK: lesson_count $PREV_LESSONS -> $CURR_LESSONS" | tee -a "$LOG"
    fi

    PREV_TRIPLES=$(jq -r '.memory_graph.triple_count // 0' "$PREV")
    CURR_TRIPLES=$(jq -r '.memory_graph.triple_count // 0' "$CURRENT")
    echo "  INFO: triple_count $PREV_TRIPLES -> $CURR_TRIPLES" | tee -a "$LOG"

    if [[ $GATE_FAIL -eq 1 ]]; then
      echo "  === CONSCIOUSNESS GATE: REGRESSION DETECTED ===" | tee -a "$LOG"
    else
      echo "  === CONSCIOUSNESS GATE: PASS ===" | tee -a "$LOG"
    fi
  fi

  # Rotate current baseline to prev for next run
  [[ -f "$CURRENT" ]] && cp "$CURRENT" "$ROOT/logs/consciousness-baseline-prev.json"
fi

# --with-judge: run the eval harness (EVAL-009 --eval-run) so the
# chump_eval_runs table actually has rows for emit_judge_summary to read.
# Falls back to legacy --eval-judge for older binaries.
if [[ $WITH_JUDGE -eq 1 ]]; then
  echo "" | tee -a "$LOG"
  echo "=== LlmJudge Eval (--with-judge) ===" | tee -a "$LOG"
  CHUMP_BIN="${CHUMP_BIN:-$ROOT/target/release/chump}"
  if [[ ! -x "$CHUMP_BIN" ]]; then
    CHUMP_BIN="$ROOT/target/debug/chump"
  fi
  if [[ -x "$CHUMP_BIN" ]]; then
    # EVAL-009: --eval-run persists EvalRunResult rows + scores judge per case
    # when CHUMP_EVAL_WITH_JUDGE=1 (already exported above).
    if "$CHUMP_BIN" --help 2>&1 | grep -q "eval-run" || true; then
      # Detect support by attempting --eval-run; if the flag is unrecognized
      # the binary will fall through to other modes — try eval-judge as
      # backup so older releases still work.
      "$CHUMP_BIN" --eval-run 2>&1 | tee -a "$LOG" || \
      "$CHUMP_BIN" --eval-judge 2>&1 | tee -a "$LOG"
    else
      "$CHUMP_BIN" --eval-judge 2>&1 | tee -a "$LOG"
    fi
  else
    echo "[with-judge] chump binary not found at $CHUMP_BIN — skipping judge run" | tee -a "$LOG"
    echo "             Build first with: cargo build --release" | tee -a "$LOG"
  fi
fi

# --with-replay: run golden-trajectory replay after main loop (EVAL-003 closes
# the live-driver acceptance clause "scripts/battle-qa.sh wires in the replay
# step"). Non-fatal — replay failures land in logs/replay/ for inspection but
# don't change battle-qa's exit code beyond what the main loop set.
if [[ $WITH_REPLAY -eq 1 ]]; then
  echo "" | tee -a "$LOG"
  echo "=== Golden Trajectory Replay (--with-replay) ===" | tee -a "$LOG"
  REPLAY_SCRIPT="$ROOT/scripts/replay-trajectory.sh"
  if [[ -x "$REPLAY_SCRIPT" ]]; then
    "$REPLAY_SCRIPT" 2>&1 | tee -a "$LOG" || true
  else
    echo "[with-replay] $REPLAY_SCRIPT not executable — skipping replay" | tee -a "$LOG"
  fi
fi

echo "=== Battle QA: FAILURES (see $FAILURES_TXT and $LOG) ===" | tee -a "$LOG"
emit_judge_summary
exit 1
