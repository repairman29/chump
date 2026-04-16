#!/usr/bin/env bash
# run-consciousness-study.sh — End-to-end consciousness A/B study.
#
# Builds release binary, runs the full 28-prompt exercise battery twice
# (consciousness ON vs OFF), captures baselines, runs analysis, and
# generates a draft research report.
#
# Usage:
#   ./scripts/run-consciousness-study.sh                   # full study
#   CHUMP_STUDY_SKIP_BUILD=1 ./scripts/run-consciousness-study.sh  # skip build
#
# Outputs:
#   logs/study-ON-baseline.json       — metrics with consciousness enabled
#   logs/study-OFF-baseline.json      — metrics with consciousness disabled
#   logs/study-ON-report.txt          — human-readable ON report
#   logs/study-OFF-report.txt         — human-readable OFF report
#   logs/study-ON-timings.jsonl       — per-prompt timing (ON)
#   logs/study-OFF-timings.jsonl      — per-prompt timing (OFF)
#   logs/study-analysis.json          — computed deltas
#   docs/CONSCIOUSNESS_AB_RESULTS.md  — draft research report

set -euo pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

LOG_DIR="$ROOT/logs"
mkdir -p "$LOG_DIR"

STUDY_ID="$(date -u +%Y%m%d-%H%M%S)"
echo "============================================"
echo "  Consciousness A/B Study — $STUDY_ID"
echo "============================================"
echo ""

# ─── Phase 1: Build ───────────────────────────────────────────────

BINARY="./target/release/chump"
if [[ "${CHUMP_STUDY_SKIP_BUILD:-}" != "1" ]]; then
  echo "Phase 1: Building release binary..."
  cargo build --release -q 2>&1
  echo "  ✅ Build complete."
else
  echo "Phase 1: Skipping build (CHUMP_STUDY_SKIP_BUILD=1)"
fi

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: Release binary not found at $BINARY"
  exit 1
fi

# ─── Detect model server ──────────────────────────────────────────

if curl -s --connect-timeout 2 http://127.0.0.1:8000/v1/models >/dev/null 2>&1; then
  export OPENAI_API_BASE="http://127.0.0.1:8000/v1"
  export OPENAI_API_KEY="mlx"
  MODEL_INFO=$(curl -s http://127.0.0.1:8000/v1/models 2>/dev/null | grep '"id"' | head -1 | sed 's/.*"id":"\([^"]*\)".*/\1/')
  export OPENAI_MODEL="${MODEL_INFO:-mlx-model}"
  echo "Model server: vLLM-MLX :8000 ($OPENAI_MODEL)"
elif curl -s --connect-timeout 2 http://127.0.0.1:11434/v1/models >/dev/null 2>&1; then
  export OPENAI_API_BASE="http://127.0.0.1:11434/v1"
  export OPENAI_API_KEY="ollama"
  export OPENAI_MODEL="${CHUMP_EXERCISE_MODEL:-qwen2.5:7b}"
  echo "Model server: Ollama :11434 ($OPENAI_MODEL)"
else
  echo "ERROR: No model server on :8000 or :11434."
  exit 1
fi

export CHUMP_REPO="$ROOT"
export CHUMP_HOME="$ROOT"

MAX_SECS="${CHUMP_EXERCISE_TIMEOUT:-240}"
HARDWARE="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
RAM_GB="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}' || echo '?')"

echo "Hardware: $HARDWARE, ${RAM_GB}GB RAM"
echo "Timeout: ${MAX_SECS}s per prompt"
echo ""

# ─── Prompt battery ───────────────────────────────────────────────

PROMPTS=(
  "memory-store-1|Remember that Jeff prefers Rust over Python for backend development"
  "memory-store-2|Remember that Chump runs on SQLite for persistence and uses Axum for the web server"
  "memory-store-3|Remember that the Discord bot uses serenity and connects to Ollama or MLX for inference"
  "memory-store-4|Remember that Mabel is a companion agent running on the Pixel phone via Termux"
  "memory-store-5|Remember that the autonomy loop picks tasks from the queue and uses planner-executor-verifier"
  "memory-recall|What do you know about the technology stack we use?"
  "read-file|Read the file src/main.rs and tell me how many modules are declared"
  "list-dir|List the files in the src/ directory"
  "read-cargo|Read Cargo.toml and list the main dependencies"
  "calc|Calculate 42 * 17 + 99"
  "read-nonexist|Read the file src/does_not_exist.rs"
  "episode-log-win|Log an episode: summary=\"Successfully built and deployed consciousness framework\" sentiment=win tags=consciousness,deployment"
  "episode-log-frustrating|Log an episode: summary=\"Memory recall returned stale context for multi-hop query\" sentiment=frustrating tags=memory,recall"
  "episode-log-loss|Log an episode: summary=\"Tool run_cli timed out during npm test execution\" sentiment=loss tags=timeout,testing"
  "episode-recent|Show me the most recent episodes"
  "task-create|Create a task: title=\"Benchmark consciousness framework memory recall quality\" notes=\"Run 50 sample queries and measure relevance\""
  "task-list|List my current tasks"
  "state-read|What is your current focus and mood?"
  "introspect|Show me your recent tool call history"
  "self-reflect|Based on your recent episodes, what patterns do you see in failures? What should we improve?"
  "memory-multihop|What technology does the companion agent on the Pixel phone use for inference, and how does that relate to Chump's architecture?"
  "mem-graph-1|Remember that the surprise tracker measures prediction errors using exponential moving average"
  "mem-graph-2|Remember that the blackboard architecture implements Global Workspace Theory for inter-module communication"
  "mem-graph-3|Remember that counterfactual reasoning extracts causal lessons from frustrating episodes"
  "mem-graph-4|Remember that the precision controller uses thermodynamic principles to balance exploration and exploitation"
  "mem-graph-5|Remember that phi proxy measures integrated information as a proxy for system coherence"
  "mem-recall-2|What do you know about the consciousness framework and its components?"
  "empty-recall|Recall memories about quantum computing on Mars"
)

# ─── Run battery ──────────────────────────────────────────────────

run_battery() {
  local condition="$1"  # "ON" or "OFF"
  local enabled="$2"    # "1" or "0"
  local timings_file="$LOG_DIR/study-${condition}-timings.jsonl"
  local exercise_log="$LOG_DIR/study-${condition}-exercise.log"

  export CHUMP_CONSCIOUSNESS_ENABLED="$enabled"

  echo "──────────────────────────────────────────"
  echo "  Condition: $condition (CHUMP_CONSCIOUSNESS_ENABLED=$enabled)"
  echo "──────────────────────────────────────────"

  # Fresh DB for this condition
  local db_dir="$ROOT/sessions"
  mkdir -p "$db_dir"
  local db_path="$db_dir/chump_memory.db"
  rm -f "$db_path" "$db_path-wal" "$db_path-shm"
  export CHUMP_MEMORY_DB_PATH="$db_path"

  > "$timings_file"
  > "$exercise_log"

  local pass=0
  local fail=0
  local total=0
  local battery_start
  battery_start=$(date +%s)

  for entry in "${PROMPTS[@]}"; do
    local label="${entry%%|*}"
    local prompt="${entry#*|}"
    total=$((total + 1))
    echo -n "  [$total/${#PROMPTS[@]}] $label ... "

    local t0 t1 elapsed code tmpout
    tmpout=$(mktemp)
    t0=$(date +%s)

    "$BINARY" --chump "$prompt" > "$tmpout" 2>>"$exercise_log" &
    local pid=$!
    elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      elapsed=$((elapsed + 1))
      if [ "$elapsed" -ge "$MAX_SECS" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        fail=$((fail + 1))
        echo "TIMEOUT (${MAX_SECS}s)"
        echo "{\"prompt\":\"$label\",\"status\":\"timeout\",\"elapsed_secs\":$elapsed,\"condition\":\"$condition\"}" >> "$timings_file"
        rm -f "$tmpout"
        continue 2
      fi
    done
    wait "$pid" 2>/dev/null || true
    code=$?
    t1=$(date +%s)
    elapsed=$((t1 - t0))

    local bytes
    bytes=$(wc -c < "$tmpout" | tr -d ' ')

    if [ "$code" -eq 0 ]; then
      pass=$((pass + 1))
      echo "OK (${bytes}b, ${elapsed}s)"
      echo "{\"prompt\":\"$label\",\"status\":\"ok\",\"elapsed_secs\":$elapsed,\"bytes\":$bytes,\"condition\":\"$condition\"}" >> "$timings_file"
    else
      fail=$((fail + 1))
      echo "FAIL (exit $code, ${elapsed}s)"
      echo "{\"prompt\":\"$label\",\"status\":\"fail\",\"exit_code\":$code,\"elapsed_secs\":$elapsed,\"condition\":\"$condition\"}" >> "$timings_file"
    fi

    cat "$tmpout" >> "$exercise_log" 2>/dev/null || true
    echo "" >> "$exercise_log"
    rm -f "$tmpout"
    sleep 1
  done

  local battery_end
  battery_end=$(date +%s)
  local battery_elapsed=$((battery_end - battery_start))

  echo ""
  echo "  Results: $pass pass / $fail fail / $total total (${battery_elapsed}s)"

  # Capture baseline
  bash "$ROOT/scripts/consciousness-baseline.sh" > /dev/null 2>&1
  cp "$LOG_DIR/consciousness-baseline.json" "$LOG_DIR/study-${condition}-baseline.json"

  # Capture report
  bash "$ROOT/scripts/consciousness-report.sh" > "$LOG_DIR/study-${condition}-report.txt" 2>&1 || true

  # Add metadata to baseline
  local tmp_meta
  tmp_meta=$(mktemp)
  python3 -c "
import json, sys
with open('$LOG_DIR/study-${condition}-baseline.json') as f:
    data = json.load(f)
data['study_metadata'] = {
    'study_id': '$STUDY_ID',
    'condition': '$condition',
    'consciousness_enabled': $enabled,
    'model': '$OPENAI_MODEL',
    'api_base': '$OPENAI_API_BASE',
    'hardware': '$HARDWARE',
    'ram_gb': $RAM_GB,
    'prompts_total': $total,
    'prompts_pass': $pass,
    'prompts_fail': $fail,
    'wall_time_secs': $battery_elapsed
}
json.dump(data, sys.stdout, indent=2)
" > "$tmp_meta" 2>/dev/null && mv "$tmp_meta" "$LOG_DIR/study-${condition}-baseline.json" || rm -f "$tmp_meta"

  echo "  Baseline: logs/study-${condition}-baseline.json"
  echo "  Report:   logs/study-${condition}-report.txt"
  echo "  Timings:  logs/study-${condition}-timings.jsonl"
  echo ""
}

# ─── Phase 2-3: Run ON condition ──────────────────────────────────

echo ""
echo "Phase 2-3: Running consciousness ON battery..."
echo ""
STUDY_START=$(date +%s)
run_battery "ON" "1"

# ─── Phase 4-5: Run OFF condition ─────────────────────────────────

echo "Phase 4-5: Running consciousness OFF battery..."
echo ""
run_battery "OFF" "0"
STUDY_END=$(date +%s)
STUDY_TOTAL=$((STUDY_END - STUDY_START))

# ─── Phase 6: Analysis ────────────────────────────────────────────

echo "Phase 6: Running analysis..."
bash "$ROOT/scripts/analyze-ab-results.sh" 2>/dev/null || echo "  (analysis script not found, skipping)"

# ─── Phase 7: Generate draft ──────────────────────────────────────

echo "Phase 7: Generating draft report..."
bash "$ROOT/scripts/generate-research-draft.sh" 2>/dev/null || echo "  (draft generator not found, skipping)"

# ─── Done ─────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  Study Complete — $STUDY_ID"
echo "  Total wall time: ${STUDY_TOTAL}s"
echo "============================================"
echo ""
echo "Outputs:"
echo "  logs/study-ON-baseline.json"
echo "  logs/study-OFF-baseline.json"
echo "  logs/study-ON-timings.jsonl"
echo "  logs/study-OFF-timings.jsonl"
echo "  logs/study-analysis.json"
echo "  docs/CONSCIOUSNESS_AB_RESULTS.md"
echo ""
echo "Next: Review docs/CONSCIOUSNESS_AB_RESULTS.md and edit for publication."
