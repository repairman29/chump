#!/usr/bin/env bash
# Generic A/B harness — runs a task set under two env configurations and
# records structural pass/fail outcomes for later statistical comparison.
#
# Usage:
#   scripts/ab-harness/run.sh \
#       --fixture scripts/ab-harness/fixtures/reflection_tasks.json \
#       --flag CHUMP_REFLECTION_INJECTION \
#       --tag reflection-ab \
#       [--limit 20] [--chump-bin ./target/release/chump]
#
# Emits:
#   logs/ab/<tag>-<unix-ts>.jsonl    one line per (task, mode) trial
#   logs/ab/<tag>-<unix-ts>.summary.json   rollup
#
# Each trial line:
#   {"tag","task_id","category","mode","success","duration_ms","tool_calls",
#    "final_text_chars","note"}
#
# Resumability: each trial is appended; re-running with the same timestamp
# file is NOT a feature — instead use --resume <existing-jsonl> to skip any
# (task_id, mode) pairs already present in the file.
#
# Design choices:
#   - Real LLM call per task (not mock). Expects an OpenAI-compatible endpoint
#     reachable at $OPENAI_API_BASE with $OPENAI_MODEL set. Won't start if
#     neither Ollama :11434 nor MLX :8000 is up.
#   - Structural property checks only. Scoring uses eval_harness::check_property
#     via the chump binary's --eval-json mode (see battle-qa.sh pattern).
#     Semantic / LLM-judge scoring is COG-011b follow-up.
#   - Deterministic order: tasks run in fixture order, A-mode then B-mode.
#     Reversed-order sanity check is a follow-up (COG-011c) — this MVP
#     biases toward "same conditions for both modes" which is what matters
#     for comparing lesson injection effect.

set -euo pipefail

FIXTURE=""
FLAG=""
TAG=""
LIMIT=""
CHUMP_BIN="./target/release/chump"
RESUME=""
ORDER="fixed"   # COG-011c: fixed (A then B), reverse (B then A), or random per task
SEED_LESSONS=""  # COG-014: optional path to a lessons JSON file to seed before the run

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture) FIXTURE="$2"; shift 2;;
    --flag) FLAG="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --limit) LIMIT="$2"; shift 2;;
    --chump-bin) CHUMP_BIN="$2"; shift 2;;
    --resume) RESUME="$2"; shift 2;;
    --order) ORDER="$2"; shift 2;;
    --seed-lessons) SEED_LESSONS="$2"; shift 2;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

case "$ORDER" in
  fixed|reverse|random) ;;
  *) echo "ERROR: --order must be fixed|reverse|random (got '$ORDER')" >&2; exit 2;;
esac

for k in FIXTURE FLAG TAG; do
  if [[ -z "${!k}" ]]; then
    echo "ERROR: --${k,,} required" >&2
    exit 2
  fi
done

# Portable timeout command: GNU `timeout` on Linux, `gtimeout` on macOS
# (brew install coreutils). Fall back to no-op on systems without either
# so the harness still runs — losing a few stalled gotcha tasks is better
# than the silent 22ms "trial" scenario we hit on first launch.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
else
  echo "[harness] WARNING: no timeout command found (brew install coreutils on macOS); running without task ceiling" >&2
fi

if [[ ! -f "$FIXTURE" ]]; then
  echo "ERROR: fixture not found: $FIXTURE" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "ERROR: $CHUMP_BIN not found or not executable. Build: cargo build --release" >&2
  exit 2
fi

# Probe the LLM endpoint — refuse to run with no provider. The harness is
# only useful with a real model; mock runs would prove nothing.
probe_endpoint() {
  local base="$1"
  curl -sf --connect-timeout 2 "$base/models" >/dev/null 2>&1
}

if [[ -z "${OPENAI_API_BASE:-}" ]]; then
  if probe_endpoint "http://127.0.0.1:11434/v1"; then
    export OPENAI_API_BASE="http://127.0.0.1:11434/v1"
    export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
    export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:7b}"
  elif probe_endpoint "http://127.0.0.1:8000/v1"; then
    export OPENAI_API_BASE="http://127.0.0.1:8000/v1"
    export OPENAI_API_KEY="${OPENAI_API_KEY:-mlx}"
    export OPENAI_MODEL="${OPENAI_MODEL:-mlx-community/Qwen3-14B-4bit}"
  else
    echo "ERROR: No LLM endpoint reachable. Start Ollama (:11434) or MLX (:8000)." >&2
    exit 3
  fi
fi

TS="$(date +%s)"
OUT_DIR="$ROOT/logs/ab"
mkdir -p "$OUT_DIR"
if [[ -n "$RESUME" ]]; then
  TRIALS="$RESUME"
  echo "[harness] resuming: $TRIALS"
else
  TRIALS="$OUT_DIR/${TAG}-${TS}.jsonl"
  : > "$TRIALS"
  echo "[harness] fresh run: $TRIALS"
fi

# Parse fixture — jq extracts task list once, shell loops.
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required for fixture parsing" >&2
  exit 2
fi

TASK_COUNT=$(jq '.tasks | length' "$FIXTURE")
if [[ -n "$LIMIT" ]]; then
  TASK_COUNT=$(( LIMIT < TASK_COUNT ? LIMIT : TASK_COUNT ))
fi

echo "[harness] fixture=$FIXTURE flag=$FLAG tag=$TAG tasks=$TASK_COUNT"
echo "[harness] model=$OPENAI_MODEL @ $OPENAI_API_BASE"
echo ""

# COG-014: Optional task-specific lesson seeding.
# Pass --seed-lessons <path-to-lessons.json> to replace generic lessons with
# domain-specific ones before the run.  The harness clears any previously
# seeded lessons first so consecutive fixture runs don't cross-contaminate.
if [[ -n "$SEED_LESSONS" ]]; then
  echo "[harness] clearing previous AB-seeded lessons…"
  "$CHUMP_BIN" --seed-ab-lessons clear 2>/dev/null || true
  echo "[harness] seeding lessons from $SEED_LESSONS…"
  "$CHUMP_BIN" --seed-ab-lessons "$SEED_LESSONS"
  echo ""
fi

# Helper: skip a (task, mode) if resume set and pair already recorded.
already_done() {
  local tid="$1" mode="$2"
  [[ -z "$RESUME" ]] && return 1
  jq -e --arg t "$tid" --arg m "$mode" \
     'select(.task_id == $t and .mode == $m)' "$TRIALS" >/dev/null 2>&1
}

run_trial() {
  local tid="$1" cat="$2" prompt="$3" mode="$4"

  if already_done "$tid" "$mode"; then
    echo "  [$mode] $tid [skip, already in resume log]"
    return
  fi

  local flag_val
  if [[ "$mode" == "A" ]]; then flag_val="1"; else flag_val="0"; fi
  export "$FLAG"="$flag_val"

  # Per-trial neuromod telemetry: if CHUMP_NEUROMOD_ENABLED=1, chump appends
  # one JSON line per turn recording DA/NA/5HT values. validate_manipulation.py
  # reads these to confirm the failure cascade actually fired (DA deviated
  # >0.05 from 1.0) before including the trial in statistical analysis.
  local telemetry_path="${OUT_DIR}/${TAG}-${TS}-neuromod-${tid}-${mode}.jsonl"
  export CHUMP_NEUROMOD_TELEMETRY_PATH="$telemetry_path"

  local start_ms
  start_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')

  # Run chump one-shot. The `--chump <prompt>` one-shot CLI prints the final
  # reply to stdout and tool calls via tracing. We capture everything,
  # count tool calls from the trace, and save the final text.
  local tmp_out tmp_err
  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  trap 'rm -f "$tmp_out" "$tmp_err"' RETURN

  # 5-minute per-task ceiling. Gotcha tasks can narrate indefinitely on
  # weak models; we'd rather mark them failed than stall the whole run.
  # `< /dev/null` is critical: under nohup chump's stdin is closed; if
  # `--chump` falls through to its interactive read_line the script errors.
  # Empirically this caused 3 silent harness deaths during the COG-011d
  # variant (c) launches before we figured it out.
  #
  # Session isolation: clear the CLI session before each task so accumulated
  # conversation history from prior tasks doesn't overflow the context window.
  # Empirically: 100+ tasks share sessions/cli/cli/messages.json and grow to
  # 20k+ tokens, causing Ollama to silently drop connections on every request.
  local session_file="${CHUMP_HOME:-$ROOT}/sessions/cli/cli/messages.json"
  if [[ -f "$session_file" ]]; then
    printf '{"session_id":"cli","messages":[],"time_stamp":"2025-11-19T00:00:00Z"}\n' > "$session_file"
  fi

  if [[ -n "$TIMEOUT_CMD" ]]; then
    $TIMEOUT_CMD 300 "$CHUMP_BIN" --chump "$prompt" \
      >"$tmp_out" 2>"$tmp_err" </dev/null || true
  else
    "$CHUMP_BIN" --chump "$prompt" \
      >"$tmp_out" 2>"$tmp_err" </dev/null || true
  fi

  local end_ms
  end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
  local duration_ms=$((end_ms - start_ms))

  local final_text
  final_text=$(cat "$tmp_out")
  local final_chars=${#final_text}

  # Tool calls = count of execution markers chump emits to STDOUT
  # ("🔧 Executing tool: <name>"). Earlier versions greped stderr for
  # "tool_call_start" tracing events; chump only emits those at trace
  # level. The 🔧 marker is always on. We append an stderr-fallback
  # grep too in case someone's running with CHUMP_TRACING_LEVEL=trace.
  #
  # The whole assignment is wrapped in `... || true` because under
  # `set -euo pipefail` a pipeline whose inner `grep -c` exits 1 (no
  # matches) propagates that 1 through pipefail and kills the script
  # via set -e on bash 5.x (inherit_errexit-like behavior in
  # command-substitution contexts). Three silent harness deaths during
  # COG-011c launches before we figured this out.
  local tool_calls
  tool_calls=$(
    {
      grep -cE "🔧 Executing tool: " "$tmp_out" 2>/dev/null || echo 0
      grep -cE "tool_call_start|Using tool '" "$tmp_err" 2>/dev/null || echo 0
    } | python3 -c "import sys; print(sum(int(l.strip() or 0) for l in sys.stdin))" 2>/dev/null
  ) || tool_calls=0
  tool_calls=${tool_calls:-0}
  tool_calls=$(echo "$tool_calls" | tr -d '[:space:]')
  [[ "$tool_calls" =~ ^[0-9]+$ ]] || tool_calls=0

  # Success heuristic: at minimum the command completed without a timeout
  # AND the final text is non-empty. Property-level scoring is done by the
  # summarizer step (ab-harness/score.py) which has the fixture in hand.
  # Capitalized for Python-literal interpolation in the heredoc below.
  local success="False"
  if [[ -n "$final_text" && $duration_ms -lt 300000 ]]; then
    success="True"
  fi

  # Sanitize final_text for JSON — strip progress markers chump prints to
  # stdout (🔧 Executing tool: X) before passing to the judge; they confuse
  # the LLM judge into thinking the model is hallucinating tool calls.
  # Cap at 4000 chars; full output lives in $tmp_out during the run.
  local text_for_json
  text_for_json=$(printf '%s' "$final_text" \
    | grep -v "🔧 Executing tool:" 2>/dev/null || true \
    | head -c 4000)

  python3 -c "
import json, sys
row = {
    'tag': '${TAG}',
    'task_id': '${tid}',
    'category': '${cat}',
    'mode': '${mode}',
    'flag': '${FLAG}',
    'flag_value': '${flag_val}',
    'success': ${success},
    'duration_ms': ${duration_ms},
    'tool_calls': ${tool_calls},
    'final_text_chars': ${final_chars},
    'telemetry_path': '${telemetry_path}',
    'final_text_preview': sys.stdin.read(),
}
print(json.dumps(row))
" <<< "$text_for_json" >>"$TRIALS"

  echo "  [$mode] $tid done ${duration_ms}ms ${tool_calls} tools"
}

for ((i=0; i<TASK_COUNT; i++)); do
  tid=$(jq -r ".tasks[$i].id" "$FIXTURE")
  cat=$(jq -r ".tasks[$i].category" "$FIXTURE")
  prompt=$(jq -r ".tasks[$i].prompt" "$FIXTURE")

  echo "[$(($i + 1))/$TASK_COUNT] $tid ($cat)"
  # COG-011c: order controls A-vs-B sequence per task. Fixed = A first
  # (legacy); reverse = B first (sanity check that lessons-effect isn't a
  # within-session state-leak artifact); random = coin flip per task.
  case "$ORDER" in
    fixed)
      run_trial "$tid" "$cat" "$prompt" "A"  # flag=1
      run_trial "$tid" "$cat" "$prompt" "B"  # flag=0
      ;;
    reverse)
      run_trial "$tid" "$cat" "$prompt" "B"
      run_trial "$tid" "$cat" "$prompt" "A"
      ;;
    random)
      if (( RANDOM % 2 )); then
        run_trial "$tid" "$cat" "$prompt" "A"
        run_trial "$tid" "$cat" "$prompt" "B"
      else
        run_trial "$tid" "$cat" "$prompt" "B"
        run_trial "$tid" "$cat" "$prompt" "A"
      fi
      ;;
  esac
done

echo ""
echo "[harness] done. Trials: $TRIALS"
echo "[harness] next: scripts/ab-harness/score.py $TRIALS $FIXTURE"
