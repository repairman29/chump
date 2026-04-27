#!/usr/bin/env bash
# eval-065-runner.sh — EVAL-065: Social Cognition n≥200/cell strict-judge sweep.
#
# Runs run-social-cognition-ab.py with --n-repeats 7 (7 × 30 tasks = 210 trials/cell ≥ 200)
# under the strict-judge rubric (--use-llm-judge --strict-judge).
#
# Designed to run detached under nohup and survive session death.
# On completion writes logs/eval-065/summary.json with aggregate results.
#
# Usage:
#   # Run detached (recommended):
#   nohup scripts/soak/eval-065-runner.sh > logs/eval-065/runner.log 2>&1 &
#   echo "PID: $!"
#
#   # Run in foreground (debugging):
#   scripts/soak/eval-065-runner.sh
#
# Cost estimate:
#   30 tasks × 7 repeats = 210 trials/cell × 2 cells = 420 subject calls
#   420 judge calls (strict-judge) = 840 total API calls
#   claude-haiku-4-5: ~$0.80/M input / $4/M output
#   Estimated: ~$0.60 total (well under $5 abort threshold)
#
# Env:
#   ANTHROPIC_API_KEY  loaded from .env if not set
#   EVAL065_MODEL      subject model (default: claude-haiku-4-5)
#   EVAL065_JUDGE      judge model   (default: claude-haiku-4-5)
#   EVAL065_N_REPEATS  repeats per task (default: 7 → 210/cell; max harness cap: 20)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

HARNESS="$REPO_ROOT/scripts/ab-harness/run-social-cognition-ab.py"
LOG_DIR="$REPO_ROOT/logs/eval-065"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/sweep-${TS}.log"
SUMMARY_FILE="$LOG_DIR/summary.json"
RESULTS_DIR="$REPO_ROOT/scripts/ab-harness/results"

MODEL="${EVAL065_MODEL:-claude-haiku-4-5}"
JUDGE_MODEL="${EVAL065_JUDGE:-claude-haiku-4-5}"
# 7 repeats × 30 fixture tasks = 210 trials per cell (≥ 200 required by EVAL-065)
N_REPEATS="${EVAL065_N_REPEATS:-7}"

mkdir -p "$LOG_DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

# Load ANTHROPIC_API_KEY from .env if not already set
if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$REPO_ROOT/.env"
    set +a
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    log "ERROR: ANTHROPIC_API_KEY not set and not found in .env — aborting"
    exit 1
fi

# Emit to ambient stream
emit_ambient() {
    if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" "$@" 2>/dev/null || true
    fi
}

# ── Cost pre-check ────────────────────────────────────────────────────────────
# Dry-run to confirm task count before spending money.
log "=== EVAL-065 RUNNER STARTING ==="
log "Model: $MODEL | Judge: $JUDGE_MODEL | n_repeats: $N_REPEATS"
log "Estimated trials: 30 tasks × ${N_REPEATS} repeats × 2 cells = $(( 30 * N_REPEATS * 2 )) total"
log "Estimated cost (haiku): ~\$$(python3 -c "print(f'{30 * $N_REPEATS * 2 * 0.00084:.2f}')")"

DRY_OUTPUT="$(python3 "$HARNESS" --dry-run --n-repeats "$N_REPEATS" 2>&1)"
log "Dry-run output:"
echo "$DRY_OUTPUT" | tee -a "$LOG_FILE"

# Confirm the trial count matches expectations
TOTAL_TRIALS="$(echo "$DRY_OUTPUT" | grep -oE 'total trials: [0-9]+' | grep -oE '[0-9]+' || echo "0")"
if [[ "${TOTAL_TRIALS:-0}" -lt 400 ]]; then
    log "WARNING: expected ≥420 total trials but dry-run reports ${TOTAL_TRIALS}. Continuing but check fixture."
fi

emit_ambient kind=eval_start gap=EVAL-065 model="$MODEL" n_repeats="$N_REPEATS" trials="${TOTAL_TRIALS:-unknown}"

# ── Run sweep ─────────────────────────────────────────────────────────────────
START_TS="$(ts)"
START_EPOCH="$(date +%s)"

log "Starting sweep at $START_TS"
log "Logs: $LOG_FILE"
log "Results dir: $RESULTS_DIR"

SWEEP_EXIT=0
python3 "$HARNESS" \
    --n-repeats "$N_REPEATS" \
    --category all \
    --model "$MODEL" \
    --use-llm-judge \
    --judge-model "$JUDGE_MODEL" \
    --strict-judge \
    2>&1 | tee -a "$LOG_FILE" || SWEEP_EXIT=$?

END_TS="$(ts)"
END_EPOCH="$(date +%s)"
ELAPSED=$(( END_EPOCH - START_EPOCH ))

# ── Collect results ───────────────────────────────────────────────────────────
# Find the most recent result file written by the harness
LATEST_RESULT="$(ls -t "$RESULTS_DIR"/eval-050-*.jsonl 2>/dev/null | head -1 || echo "")"

log "=== SWEEP COMPLETE ==="
log "Exit code: $SWEEP_EXIT"
log "Elapsed: ${ELAPSED}s"
log "Latest result file: ${LATEST_RESULT:-none}"

# Parse quick summary from log output
CELL_A_RATE="$(grep -oE 'cell_a.*clarification_rate=[0-9.]+' "$LOG_FILE" | tail -1 | grep -oE '[0-9.]+$' || echo "n/a")"
CELL_B_RATE="$(grep -oE 'cell_b.*clarification_rate=[0-9.]+' "$LOG_FILE" | tail -1 | grep -oE '[0-9.]+$' || echo "n/a")"

# ── Write summary.json ────────────────────────────────────────────────────────
python3 - <<PYEOF
import json, os, pathlib, subprocess

summary = {
    "gap": "EVAL-065",
    "run_ts": "$START_TS",
    "end_ts": "$END_TS",
    "elapsed_sec": $ELAPSED,
    "exit_code": $SWEEP_EXIT,
    "model": "$MODEL",
    "judge_model": "$JUDGE_MODEL",
    "n_repeats": $N_REPEATS,
    "total_trials_expected": $(( 30 * N_REPEATS * 2 )),
    "result_file": "${LATEST_RESULT:-}",
    "log_file": "$LOG_FILE",
    "status": "complete" if $SWEEP_EXIT == 0 else "failed",
}

out = pathlib.Path("$SUMMARY_FILE")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(summary, indent=2) + "\n")
print(f"Summary written to {out}")
PYEOF

emit_ambient kind=eval_end gap=EVAL-065 exit_code="$SWEEP_EXIT" elapsed="${ELAPSED}s" result_file="${LATEST_RESULT:-none}"

if [[ "$SWEEP_EXIT" -eq 0 ]]; then
    log "SUCCESS: sweep completed. See $SUMMARY_FILE for details."
    log "Next step: run analysis and update docs/eval/EVAL-050-social-cognition.md (PR-B)"
else
    log "ERROR: sweep exited with code $SWEEP_EXIT — check $LOG_FILE"
    exit "$SWEEP_EXIT"
fi
