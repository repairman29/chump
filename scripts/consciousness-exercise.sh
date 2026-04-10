#!/usr/bin/env bash
# consciousness-exercise.sh — Drive Chump through a battery of diverse tasks
# to populate all 6 consciousness framework subsystems with real data.
#
# Uses OPENAI_API_BASE=http://127.0.0.1:8000/v1 (MLX) when :8000 is up, else Ollama :11434.
# On Ollama, defaults to qwen2.5:7b for reliable latency with large context (ignores OPENAI_MODEL from .env).
# Override: CHUMP_EXERCISE_MODEL=llama3.2:3b  CHUMP_EXERCISE_TIMEOUT=240  ./scripts/consciousness-exercise.sh

set -euo pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

# Use MLX (8000) if alive, else Ollama (11434)  
if curl -s --connect-timeout 2 http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then
  export OPENAI_API_BASE="http://127.0.0.1:8000/v1"
  export OPENAI_API_KEY="mlx"
  export OPENAI_MODEL="mlx-community/Qwen3-14B-4bit"
elif curl -s --connect-timeout 2 http://127.0.0.1:11434/v1/models >/dev/null 2>&1; then
  export OPENAI_API_BASE="http://127.0.0.1:11434/v1"
  export OPENAI_API_KEY="ollama"
  # Do not inherit OPENAI_MODEL from .env (often 14B); exercise needs faster local model.
  unset OPENAI_MODEL
  export OPENAI_MODEL="${CHUMP_EXERCISE_MODEL:-qwen2.5:7b}"
else
  echo "ERROR: No model server on :8000 or :11434. Start MLX or Ollama first."
  exit 1
fi
export CHUMP_REPO="$ROOT"
export CHUMP_HOME="$ROOT"

BINARY="./target/release/chump"
if [[ ! -x "$BINARY" ]]; then
  echo "Release binary not found. Building..."
  cargo build --release -q
fi

MAX_SECS="${CHUMP_EXERCISE_TIMEOUT:-240}"
PASS=0
FAIL=0
TOTAL=0
LOG="$ROOT/logs/consciousness-exercise.log"
mkdir -p "$ROOT/logs"
> "$LOG"

# macOS lacks coreutils timeout; implement via background + kill
run_prompt() {
  local label="$1"
  local prompt="$2"
  TOTAL=$((TOTAL + 1))
  echo -n "  [$TOTAL] $label ... "
  local tmpout
  tmpout=$(mktemp)
  "$BINARY" --chump "$prompt" > "$tmpout" 2>>"$LOG" &
  local pid=$!
  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$MAX_SECS" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      FAIL=$((FAIL + 1))
      echo "TIMEOUT (${MAX_SECS}s)"
      echo "--- [$TOTAL] $label: TIMEOUT ---" >> "$LOG"
      rm -f "$tmpout"
      return
    fi
  done
  wait "$pid" || true
  local code=$?
  local out
  out=$(cat "$tmpout")
  rm -f "$tmpout"
  if [ "$code" -eq 0 ]; then
    PASS=$((PASS + 1))
    local bytes
    bytes=$(echo "$out" | wc -c | tr -d ' ')
    echo "OK (${bytes}b, ${elapsed}s)"
    echo "--- [$TOTAL] $label: OK ---" >> "$LOG"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL (exit $code, ${elapsed}s)"
    echo "--- [$TOTAL] $label: FAIL (exit $code) ---" >> "$LOG"
  fi
  echo "$out" >> "$LOG" 2>/dev/null || true
  echo "" >> "$LOG"
  sleep 1
}

echo "=== Consciousness Exercise Battery ==="
echo "Model: $OPENAI_MODEL @ $OPENAI_API_BASE"
echo "Timeout: ${MAX_SECS}s per prompt"
echo "Log: $LOG"
echo ""

START_TS=$(date +%s)

# --- Round 1: Memory operations (populates memory graph triples) ---
echo "Round 1: Memory operations"
run_prompt "memory-store-1" "Remember that Jeff prefers Rust over Python for backend development"
run_prompt "memory-store-2" "Remember that Chump runs on SQLite for persistence and uses Axum for the web server"
run_prompt "memory-store-3" "Remember that the Discord bot uses serenity and connects to Ollama or MLX for inference"
run_prompt "memory-store-4" "Remember that Mabel is a companion agent running on the Pixel phone via Termux"
run_prompt "memory-store-5" "Remember that the autonomy loop picks tasks from the queue and uses planner-executor-verifier"
run_prompt "memory-recall" "What do you know about the technology stack we use?"

# --- Round 2: Tool-heavy operations (populates surprise tracker) ---
echo ""
echo "Round 2: Tool operations"
run_prompt "read-file" "Read the file src/main.rs and tell me how many modules are declared"
run_prompt "list-dir" "List the files in the src/ directory"
run_prompt "read-cargo" "Read Cargo.toml and list the main dependencies"
run_prompt "calc" "Calculate 42 * 17 + 99"
run_prompt "read-nonexist" "Read the file src/does_not_exist.rs"

# --- Round 3: Episode logging (populates episodic memory + counterfactual) ---
echo ""
echo "Round 3: Episode operations"
run_prompt "episode-log-win" 'Log an episode: summary="Successfully built and deployed consciousness framework" sentiment=win tags=consciousness,deployment'
run_prompt "episode-log-frustrating" 'Log an episode: summary="Memory recall returned stale context for multi-hop query" sentiment=frustrating tags=memory,recall'
run_prompt "episode-log-loss" 'Log an episode: summary="Tool run_cli timed out during npm test execution" sentiment=loss tags=timeout,testing'
run_prompt "episode-recent" "Show me the most recent episodes"

# --- Round 4: Task operations ---
echo ""
echo "Round 4: Task operations"
run_prompt "task-create" 'Create a task: title="Benchmark consciousness framework memory recall quality" notes="Run 50 sample queries and measure relevance of top-5 recall results"'
run_prompt "task-list" "List my current tasks"

# --- Round 5: Complex reasoning (exercises context assembly, precision regime) ---
echo ""
echo "Round 5: Complex reasoning"
run_prompt "state-read" "What is your current focus and mood?"
run_prompt "introspect" "Show me your recent tool call history"
run_prompt "self-reflect" "Based on your recent episodes, what patterns do you see in failures? What should we improve?"
run_prompt "memory-multihop" "What technology does the companion agent on the Pixel phone use for inference, and how does that relate to Chump's architecture?"

# --- Round 6: More memory to build graph density ---
echo ""
echo "Round 6: Graph density"
run_prompt "mem-6a" "Remember that the surprise tracker measures prediction errors using exponential moving average"
run_prompt "mem-6b" "Remember that the blackboard architecture implements Global Workspace Theory for inter-module communication"
run_prompt "mem-6c" "Remember that counterfactual reasoning extracts causal lessons from frustrating episodes"
run_prompt "mem-6d" "Remember that the precision controller uses thermodynamic principles to balance exploration and exploitation"
run_prompt "mem-6e" "Remember that phi proxy measures integrated information as a proxy for system coherence"
run_prompt "mem-recall-2" "What do you know about the consciousness framework and its components?"

# --- Round 7: Edge cases and errors (exercises circuit breaker, high surprisal) ---
echo ""
echo "Round 7: Edge cases"
run_prompt "empty-recall" "Recall memories about quantum computing on Mars"
run_prompt "episode-search" "Search episodes for timeout"
run_prompt "episode-sentiment" "Show me recent frustrating episodes"

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

echo ""
echo "=== Exercise Complete ==="
echo "  Total: $TOTAL | Pass: $PASS | Fail: $FAIL | Time: ${ELAPSED}s"
echo "  Log: $LOG"
echo ""
echo "=== Post-Exercise Consciousness Report ==="
echo ""
bash "$ROOT/scripts/consciousness-report.sh"
echo ""
echo "=== Capturing AFTER baseline ==="
bash "$ROOT/scripts/consciousness-baseline.sh"
cp "$ROOT/logs/consciousness-baseline.json" "$ROOT/logs/consciousness-baseline-AFTER.json"
echo ""
echo "Compare: diff logs/consciousness-baseline-BEFORE.json logs/consciousness-baseline-AFTER.json"
