#!/usr/bin/env bash
# Dogfood matrix: end-to-end defense suite for Chump.
#
# Runs a set of real agent turns against the live chump binary + model backend.
# Catches cross-boundary bugs (concurrent LLM requests, vLLM Metal crashes,
# token budget interactions, session bloat) that unit tests do NOT cover.
#
# The canonical example this suite was born from: a read_file of src/main.rs
# triggered delegate_tool::run_delegate_summarize(), which sent a concurrent
# LLM request to vLLM-MLX (max_num_seqs=1), blocked the inference queue, and
# crashed Metal on the next agent call. 336/337 unit tests were passing the
# whole time.
#
# Usage:
#   ./scripts/eval/dogfood-matrix.sh                   # run all scenarios
#   ./scripts/eval/dogfood-matrix.sh --quick           # fastest 3 (smoke)
#   ./scripts/eval/dogfood-matrix.sh --scenario=read-large
#   ./scripts/eval/dogfood-matrix.sh --list            # list scenarios & exit
#
# Output:
#   logs/dogfood-matrix/<ts>/<scenario>.stdout    # chump stdout+stderr
#   logs/dogfood-matrix/<ts>/<scenario>.vllm      # vLLM log slice for this run
#   logs/dogfood-matrix/<ts>/report.json          # structured result
#   logs/dogfood-matrix/<ts>/summary.txt          # human-readable summary
#
# Exit:
#   0  all scenarios pass
#   1  one or more scenarios failed (report written)
#   2  setup failed (no vLLM, build broken, bad args)
#
# Pass criteria per scenario:
#   - chump exit code == 0
#   - chump stdout+stderr does NOT contain "model HTTP unreachable"
#   - vLLM log slice does NOT contain "MTLCommandBuffer" / "Metal assertion" / "failed assertion"
#   - completes within per-scenario timeout
#   - stdout final line is not empty (model produced SOME output)
#
# Add scenarios by appending to SCENARIOS below: "name|timeout_secs|prompt"

set -uo pipefail  # NOT -e: we want to continue past failing scenarios

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

# ---- arg parsing ---------------------------------------------------------
MODE="all"
ONLY=""
LIST_ONLY=0
for a in "$@"; do
  case "$a" in
    --quick) MODE="quick" ;;
    --list) LIST_ONLY=1 ;;
    --scenario=*) ONLY="${a#--scenario=}"; MODE="one" ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    *)
      echo "Unknown arg: $a" >&2; exit 2 ;;
  esac
done

# ---- scenario matrix -----------------------------------------------------
# Format: name|timeout_secs|prompt
# Keep prompts deterministic (read-only, short expected outputs) so repeated
# runs produce comparable signals. Prefer line ranges over full-file reads
# to stay within completion token budgets.
SCENARIOS=(
  "chat|60|Say hi and tell me in one sentence what you are."
  "task-list|180|List all open tasks using the task tool."
  "read-small|180|Read Cargo.toml using read_file and tell me the package name."
  "read-line-range|240|Read src/main.rs lines 1-30 using read_file and count the mod declarations."
  "multi-tool|360|List all open tasks using the task tool, then read Cargo.toml using read_file and report the package version."
  "rg-search|240|Use run_cli to run 'rg --version' and report the version number."
  "read-large-lines|360|Read src/agent_loop.rs lines 1-60 using read_file and report the first pub fn name."
  # Regression guard for the delegate_summarize crash (Apr 2026): reading a file
  # WITHOUT a line range takes the max_chars truncation path. If anyone
  # reintroduces the in-tool LLM summarize call, this scenario will crash vLLM
  # (Metal assertion) and the matrix will file a task. Keep using a file that
  # is reliably larger than CHUMP_READ_FILE_MAX_CHARS (default 12000).
  "full-file-read|420|Read src/local_openai.rs using read_file (no line range) and answer in one sentence: what HTTP endpoint does the module call?"
)

QUICK_SET=("chat" "task-list" "read-line-range")

if [[ "$LIST_ONLY" == "1" ]]; then
  printf "%-20s %-8s %s\n" "SCENARIO" "TIMEOUT" "PROMPT"
  for s in "${SCENARIOS[@]}"; do
    IFS='|' read -r name timeout prompt <<<"$s"
    printf "%-20s %-8s %s\n" "$name" "${timeout}s" "$prompt"
  done
  exit 0
fi

# ---- env (same pattern as dogfood-run.sh) --------------------------------
export CHUMP_TOOL_PROFILE=full
export CHUMP_REPO="$ROOT"
export CHUMP_HOME="$ROOT"
export CHUMP_TEST_AWARE=1
export CHUMP_AUTO_APPROVE_TOOLS="run_cli,read_file,write_file,patch_file,rg,task,memory_brain,list_files,list_dir"
export CHUMP_AUTO_APPROVE_LOW_RISK=1

# Preserve caller-provided tuning knobs across .env source
_PRESERVE_VARS="OPENAI_MODEL OPENAI_API_BASE OPENAI_API_KEY \
CHUMP_OLLAMA_NUM_CTX CHUMP_OLLAMA_KEEP_ALIVE \
CHUMP_TOOL_TIMEOUT_SECS CHUMP_COMPLETION_MAX_TOKENS \
CHUMP_MODEL_REQUEST_TIMEOUT_SECS CHUMP_OPENAI_CONNECT_TIMEOUT_SECS \
VLLM_MAX_TOKENS VLLM_CACHE_PERCENT VLLM_MODEL"
_SAVED=""
for v in $_PRESERVE_VARS; do
  if [[ -n "${!v:-}" ]]; then
    _SAVED="$_SAVED export $v=$(printf %q "${!v}");"
  fi
done
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi
eval "$_SAVED"

# Higher completion cap for matrix — many scenarios are multi-tool.
export CHUMP_COMPLETION_MAX_TOKENS="${CHUMP_COMPLETION_MAX_TOKENS:-2048}"

# ---- output paths --------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$ROOT/logs/dogfood-matrix/$TS"
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"
REPORT="$OUTDIR/report.json"
VLLM_LOG="$ROOT/logs/vllm-mlx-8000.log"

log() { echo "$@" | tee -a "$SUMMARY"; }

log "=== Chump dogfood matrix: $TS ==="
log "Repo:  $ROOT"
log "Model: ${OPENAI_MODEL:-unknown}"
log "Mode:  $MODE${ONLY:+ (scenario=$ONLY)}"
log "Out:   $OUTDIR"
log ""

# ---- pre-flight checks ---------------------------------------------------
BIN="$ROOT/target/release/chump"
if [[ ! -x "$BIN" ]]; then
  log "Building release binary..."
  if ! cargo build --release --bin chump 2>&1 | tail -3 | tee -a "$SUMMARY"; then
    log "SETUP-FAIL: cargo build failed"
    exit 2
  fi
fi

# Health-check the model backend. We don't start/restart it — the matrix is
# meant to catch *drift*, and spinning up vLLM ourselves would mask "vLLM is
# unhealthy" as a passing run. If the user wants auto-start, they can wire
# scripts/setup/restart-vllm-if-down.sh into their scheduler.
MODEL_BASE="${OPENAI_API_BASE:-http://127.0.0.1:8000/v1}"
if ! curl -fsS --max-time 5 "$MODEL_BASE/models" >/dev/null 2>&1; then
  log "SETUP-FAIL: model backend unreachable at $MODEL_BASE/models"
  log "  Try: ./serve-vllm-mlx.sh  (or scripts/setup/restart-vllm-if-down.sh)"
  exit 2
fi
log "Backend OK: $MODEL_BASE"
log ""

# ---- scenario runner -----------------------------------------------------
# Returns 0=pass, 1=fail. Writes per-scenario logs under $OUTDIR.
# Stores scalar result vars: R_STATUS, R_EXIT, R_DUR_MS, R_REASON
run_scenario() {
  local name="$1" timeout_s="$2" prompt="$3"
  local sout="$OUTDIR/$name.stdout"
  local svllm="$OUTDIR/$name.vllm"

  # Snapshot vLLM log size so we can slice just this scenario's output
  local vllm_before=0
  if [[ -f "$VLLM_LOG" ]]; then
    vllm_before=$(wc -c <"$VLLM_LOG" | tr -d ' ')
  fi

  local start_ms
  start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

  # Use `timeout` (coreutils) — will exit 124 on timeout. macOS has it as `gtimeout`.
  local TIMEOUT_BIN
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
  else
    # Fallback: no timeout enforcement (scheduler should kill us)
    TIMEOUT_BIN=""
  fi

  local exit_code=0
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" --preserve-status "${timeout_s}s" "$BIN" --chump "$prompt" >"$sout" 2>&1 || exit_code=$?
  else
    "$BIN" --chump "$prompt" >"$sout" 2>&1 || exit_code=$?
  fi

  local end_ms
  end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  R_DUR_MS=$((end_ms - start_ms))
  R_EXIT=$exit_code

  # Slice vLLM log
  if [[ -f "$VLLM_LOG" ]]; then
    tail -c +"$((vllm_before + 1))" "$VLLM_LOG" >"$svllm" 2>/dev/null || : >"$svllm"
  else
    : >"$svllm"
  fi

  # ---- evaluate -------------------------------------------------------
  local reason=""
  if [[ "$exit_code" == "124" ]]; then
    reason="timeout after ${timeout_s}s"
  elif [[ "$exit_code" != "0" ]]; then
    reason="chump exit=$exit_code"
  elif grep -q "model HTTP unreachable" "$sout" 2>/dev/null; then
    reason="model HTTP unreachable (backend crashed mid-turn)"
  elif grep -qE "MTLCommandBuffer|failed assertion|Metal assertion" "$svllm" 2>/dev/null; then
    reason="vLLM Metal crash detected in log slice"
  elif ! [[ -s "$sout" ]] || [[ "$(tail -c 100 "$sout" | tr -d '[:space:]')" == "" ]]; then
    reason="empty output"
  fi

  if [[ -z "$reason" ]]; then
    R_STATUS="pass"
    R_REASON=""
    return 0
  else
    R_STATUS="fail"
    R_REASON="$reason"
    return 1
  fi
}

# ---- main loop -----------------------------------------------------------
declare -a RESULTS=()
FAILS=0
PASSES=0

should_run() {
  local name="$1"
  case "$MODE" in
    all) return 0 ;;
    quick)
      for q in "${QUICK_SET[@]}"; do
        [[ "$q" == "$name" ]] && return 0
      done
      return 1 ;;
    one) [[ "$name" == "$ONLY" ]] && return 0 || return 1 ;;
  esac
  return 1
}

for s in "${SCENARIOS[@]}"; do
  IFS='|' read -r name timeout_s prompt <<<"$s"
  should_run "$name" || continue

  printf "%-20s ... " "$name" | tee -a "$SUMMARY"
  run_scenario "$name" "$timeout_s" "$prompt"
  rc=$?

  if [[ "$rc" == "0" ]]; then
    PASSES=$((PASSES + 1))
    printf "PASS  (%dms)\n" "$R_DUR_MS" | tee -a "$SUMMARY"
  else
    FAILS=$((FAILS + 1))
    printf "FAIL  (%dms) — %s\n" "$R_DUR_MS" "$R_REASON" | tee -a "$SUMMARY"
  fi

  # Accumulate JSON row
  RESULTS+=("$(printf '{"name":"%s","status":"%s","exit":%d,"duration_ms":%d,"reason":"%s","timeout_s":%d,"prompt":%s}' \
    "$name" "$R_STATUS" "$R_EXIT" "$R_DUR_MS" "${R_REASON//\"/\\\"}" "$timeout_s" \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$prompt")" )")
done

log ""
log "=== Summary: $PASSES passed, $FAILS failed ==="

# ---- write report.json ---------------------------------------------------
{
  printf '{\n'
  printf '  "timestamp": "%s",\n' "$TS"
  printf '  "model": "%s",\n' "${OPENAI_MODEL:-unknown}"
  printf '  "backend": "%s",\n' "$MODEL_BASE"
  printf '  "mode": "%s",\n' "$MODE"
  printf '  "passes": %d,\n' "$PASSES"
  printf '  "fails":  %d,\n' "$FAILS"
  printf '  "results": [\n'
  for i in "${!RESULTS[@]}"; do
    if (( i < ${#RESULTS[@]} - 1 )); then
      printf '    %s,\n' "${RESULTS[$i]}"
    else
      printf '    %s\n' "${RESULTS[$i]}"
    fi
  done
  printf '  ]\n'
  printf '}\n'
} >"$REPORT"

log ""
log "Report: $REPORT"
log "Logs:   $OUTDIR/"

if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
exit 0
