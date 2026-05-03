#!/usr/bin/env bash
# run-cog032-pilot.sh — INFRA-393 — minimal serial trial runner for COG-032
#
# v0.1 contract: run N trials in ONE cell, serially. Per the COG-032 prereg
# §3 the canonical sweep interleaves A/B/C per task; this script does NOT
# do that. It runs N trials in a single cell so an operator can validate
# the harness path end-to-end before committing budget to the full sweep.
# RESEARCH_INTEGRITY.md "Calibrate the chain at n=5" rule: this is the
# canonical pre-flight script for that calibration.
#
# Per trial:
#   1. Pick a task (round-robin if n > task_count) from the bench fixture.
#   2. Create a fresh worktree at .chump/worktrees/cog032-<cell>-<task>-<n>/.
#   3. Set the per-trial env: CHUMP_BENCH_MODE=1 + cell/task/trial metadata
#      + CHUMP_LESSONS_AT_SPAWN_N (0 for Cell A, 5 for B/C).
#   4. Spawn `claude -p --dangerously-skip-permissions` with the task
#      instruction. 90-min wall-clock timeout (per prereg §4).
#   5. The agent runs `scripts/coord/bot-merge.sh` per its task instruction;
#      under CHUMP_BENCH_MODE=1, bot-merge.sh emits the trial JSONL line
#      to logs/ab/COG-032/run.jsonl (INFRA-390). This wrapper does NOT
#      duplicate the recording.
#   6. Tear down the worktree (best-effort) so target/ reclaims disk.
#
# Deferred to INFRA-NNN follow-up:
#   - Interleaved A/B/C-per-task ordering (prereg §3 §4)
#   - Async parallel trials (today's serial = ~7.5h for n=5/cell × 3 cells)
#   - Resilience to API errors mid-trial (retry, mark partial)
#   - Lessons-snapshot to logs/ab/COG-032/lessons_snapshot.sql per prereg §8
#   - Binary mtime + commit SHA capture in run.jsonl
#
# Usage:
#   run-cog032-pilot.sh --cell A --n 5
#   run-cog032-pilot.sh --cell B --n 5 --bench-file <path>
#   run-cog032-pilot.sh --cell A --n 5 --dry-run

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CELL=""
N=5
DRY_RUN=0
BENCH_FILE="$REPO_ROOT/scripts/ab-harness/fixtures/cog032_gap_bench_v1.json"
TIMEOUT_S=5400  # 90 min per prereg §4

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cell)        CELL="$2"; shift 2 ;;
        --n)           N="$2"; shift 2 ;;
        --bench-file)  BENCH_FILE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --timeout-s)   TIMEOUT_S="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$CELL" ]] || [[ ! "$CELL" =~ ^[ABC]$ ]]; then
    echo "ERROR: --cell A|B|C required" >&2
    exit 2
fi
if [[ ! -f "$BENCH_FILE" ]]; then
    echo "ERROR: bench fixture not found at $BENCH_FILE" >&2
    exit 2
fi
if ! [[ "$N" =~ ^[0-9]+$ ]] || [[ "$N" -lt 1 ]]; then
    echo "ERROR: --n must be a positive integer" >&2
    exit 2
fi

# CHUMP_LESSONS_AT_SPAWN_N matrix: A is the no-lessons control, B is the
# treatment, C is A/A noise (same as B by construction; the prereg uses
# A/A delta to bound judge variance).
case "$CELL" in
    A) LESSONS_N=0 ;;
    B|C) LESSONS_N=5 ;;
esac

# Pull task IDs from the bench fixture. macOS bash 3.x lacks `mapfile` so
# we read into an array via a portable `while read` loop.
TASK_IDS=()
while IFS= read -r _tid; do
    [[ -n "$_tid" ]] && TASK_IDS+=("$_tid")
done < <(python3 -c "
import json, sys
with open('$BENCH_FILE') as f:
    d = json.load(f)
for t in d.get('tasks', []):
    print(t['id'])
")

if [[ "${#TASK_IDS[@]}" -lt 1 ]]; then
    echo "ERROR: bench fixture has no tasks" >&2
    exit 2
fi

LOG_DIR="$REPO_ROOT/logs/ab/COG-032"
mkdir -p "$LOG_DIR"
PILOT_LOG="$LOG_DIR/pilot-cell-${CELL}-$(date +%Y%m%d-%H%M%S).log"

echo "== COG-032 pilot v0.1 (INFRA-393) =="
echo "  cell:        $CELL (CHUMP_LESSONS_AT_SPAWN_N=$LESSONS_N)"
echo "  trials (n):  $N"
echo "  bench file:  $BENCH_FILE  (${#TASK_IDS[@]} tasks)"
echo "  timeout:     ${TIMEOUT_S}s per trial"
echo "  log file:    $PILOT_LOG"
echo "  dry-run:     $DRY_RUN"
echo

run_one_trial() {
    local trial_n="$1"
    # Round-robin pick: trial_n=1 → tasks[0], trial_n=2 → tasks[1], …
    local idx=$(( (trial_n - 1) % ${#TASK_IDS[@]} ))
    local task_id="${TASK_IDS[$idx]}"
    local wt_path="$REPO_ROOT/.chump/worktrees/cog032-${CELL}-${task_id}-${trial_n}"
    local branch="cog032-${CELL}-${task_id}-${trial_n}"

    # Pull this trial's instruction text from the fixture.
    local instruction
    instruction=$(BENCH="$BENCH_FILE" TID="$task_id" python3 -c '
import json, os
with open(os.environ["BENCH"]) as f:
    d = json.load(f)
for t in d.get("tasks", []):
    if t["id"] == os.environ["TID"]:
        print(t["instruction"])
        break
')

    {
        echo
        echo "── trial $trial_n / $N — task $task_id ──"
        echo "  worktree: $wt_path"
        echo "  branch:   $branch"
        echo "  env:      CHUMP_BENCH_MODE=1 CHUMP_BENCH_CELL=$CELL CHUMP_BENCH_TASK_ID=$task_id CHUMP_BENCH_TRIAL_N=$trial_n CHUMP_LESSONS_AT_SPAWN_N=$LESSONS_N"
        echo "  instruction (first 200 char): ${instruction:0:200}"
    } | tee -a "$PILOT_LOG"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [dry-run] skipping execution" | tee -a "$PILOT_LOG"
        return 0
    fi

    # Real run: create the worktree, spawn claude, wait. Best-effort cleanup.
    if ! git -C "$REPO_ROOT" worktree add "$wt_path" -b "$branch" origin/main 2>>"$PILOT_LOG"; then
        echo "  WARN: worktree add failed; skipping trial" | tee -a "$PILOT_LOG"
        return 1
    fi

    (
        cd "$wt_path" || exit 99
        export CHUMP_BENCH_MODE=1
        export CHUMP_BENCH_CELL="$CELL"
        export CHUMP_BENCH_TASK_ID="$task_id"
        export CHUMP_BENCH_TRIAL_N="$trial_n"
        export CHUMP_LESSONS_AT_SPAWN_N="$LESSONS_N"
        export CHUMP_LESSONS_DOMAIN="infra"
        export CHUMP_SESSION_ID="cog032-${CELL}-${task_id}-${trial_n}-$$"
        gtimeout "$TIMEOUT_S" claude -p --dangerously-skip-permissions "$instruction" \
            2>&1 | tee -a "$PILOT_LOG"
    )
    local rc=$?
    echo "  trial $trial_n exit: $rc" | tee -a "$PILOT_LOG"

    # Best-effort worktree teardown — keep the branch around for inspection.
    git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true

    return 0
}

for n in $(seq 1 "$N"); do
    run_one_trial "$n"
done

echo
echo "== pilot complete =="
echo "  log:      $PILOT_LOG"
echo "  trial telemetry: $LOG_DIR/run.jsonl  (emitted by bot-merge.sh under CHUMP_BENCH_MODE)"
echo
echo "Next: inspect run.jsonl entries for cell=$CELL"
echo "  jq 'select(.cell == \"$CELL\")' $LOG_DIR/run.jsonl"
