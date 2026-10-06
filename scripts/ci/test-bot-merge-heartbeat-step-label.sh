#!/usr/bin/env bash
# RESILIENT-140: bot-merge's heartbeat prints the contents of the step file.
# That file must follow named steps (_bm_step_start) and fall back to the
# current named step when a stage finishes, so a stall in push / pr-create
# is never labelled with a stale prior stage such as "cargo fmt".
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract the two functions under test (top-level definitions end at a lone "}").
extract() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {p=1} p {print} p && /^}$/ {exit}' "$BM"; }
{
  echo 'info() { :; }; _bm_ms_now() { echo 0; }; _bm_steps_append() { :; }'
  echo '_BM_PID=1; GAP_IDS=(T-1); BRANCH=b; __STAGE_T0=$(date +%s); __STAGE_BUDGET_PID=""'
  extract _bm_step_start
  extract stage_done
} > "$TMP/fns.sh"
grep -q '_bm_step_start()' "$TMP/fns.sh" && grep -q 'stage_done()' "$TMP/fns.sh" \
  || { echo "[FAIL] could not extract functions"; exit 1; }

export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
bash -c '
  source "'"$TMP"'/fns.sh"
  _BM_STEP_FILE="'"$TMP"'/step"
  printf cargo\ fmt > "$_BM_STEP_FILE"; __STAGE_LABEL="cargo fmt"

  _bm_step_start push
  [[ "$(cat "$_BM_STEP_FILE")" == "push" ]] || { echo "[FAIL] step file not updated by _bm_step_start: $(cat "$_BM_STEP_FILE")"; exit 1; }

  __STAGE_LABEL="git push"; printf "git push" > "$_BM_STEP_FILE"
  stage_done
  [[ "$(cat "$_BM_STEP_FILE")" == "push" ]] || { echo "[FAIL] step file stale after stage_done: $(cat "$_BM_STEP_FILE")"; exit 1; }
  echo "[PASS] heartbeat step label tracks the current step"
'
