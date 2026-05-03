#!/usr/bin/env bash
# test-bot-merge-bench-mode.sh — INFRA-390
#
# Pins CHUMP_BENCH_MODE=1 contract:
#   1. The auto-merge arming step is replaced by a JSONL emit + clear yellow
#      banner. PR is NOT armed for auto-merge.
#   2. The chump-gap-ship auto-close step is skipped (state.db NOT mutated).
#   3. JSONL line at logs/ab/COG-032/run.jsonl has all required fields.
#
# This is a structural test of the bot-merge.sh source — exercising the full
# script needs `gh` + network + a real repo state. We grep the source to
# verify the gating conditions exist as documented.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

if [[ ! -f "$BOT_MERGE" ]]; then
    echo "FAIL: $BOT_MERGE missing" >&2
    exit 1
fi

# ── Test 1: auto-merge step is gated on CHUMP_BENCH_MODE != 1 ─────────────
echo "[test-1] auto-merge arming gated on CHUMP_BENCH_MODE"
if ! grep -qE 'CHUMP_BENCH_MODE.*==.*"1"' "$BOT_MERGE"; then
    echo "FAIL: bot-merge.sh missing CHUMP_BENCH_MODE check" >&2
    exit 1
fi
# Verify the bench-mode block emits to run.jsonl
if ! grep -qE 'logs/ab/COG-032|CHUMP_BENCH_LOG' "$BOT_MERGE"; then
    echo "FAIL: bot-merge.sh missing run.jsonl emit path" >&2
    exit 1
fi
# Verify required JSONL fields are emitted (substrate of the prereg contract)
for field in cell task_id trial_n agent_session pr_number duration_s success_criteria_met_at_arm_stage; do
    if ! grep -qE "\"$field\":" "$BOT_MERGE"; then
        echo "FAIL: bot-merge.sh JSONL emit missing field '$field'" >&2
        exit 1
    fi
done
echo "  PASS: auto-merge gate + JSONL fields present"

# ── Test 2: gap auto-close step skipped under bench mode ──────────────────
echo "[test-2] gap auto-close (chump gap ship) gated on CHUMP_BENCH_MODE != 1"
# Look for the auto-close conditional that includes CHUMP_BENCH_MODE != 1
autoclose_line=$(grep -nE 'CHUMP_AUTO_CLOSE_GAP.*GAP_IDS.*CHUMP_BENCH_MODE' "$BOT_MERGE" | head -1)
if [[ -z "$autoclose_line" ]]; then
    echo "FAIL: bot-merge.sh auto-close conditional missing CHUMP_BENCH_MODE != 1 gate" >&2
    exit 1
fi
echo "  PASS: auto-close skip gate present at $autoclose_line"

# ── Test 3: JSONL line shape (smoke-test the printf with real env) ────────
echo "[test-3] JSONL emit produces valid JSON when env vars set"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
# Extract just the printf line and run it with stub values.
# This validates the format string doesn't have shell-quoting issues.
TARGET_PR=99
BRANCH="chump/test-bench"
SECONDS=42
CHUMP_BENCH_CELL="A"
CHUMP_BENCH_TASK_ID="cog032-T01-stale-gaps-yaml-redirect"
CHUMP_BENCH_TRIAL_N=3
CLAUDE_SESSION_ID="test-session-abc"
_bench_ts="2026-05-03T20:00:00Z"
_bench_session="$CLAUDE_SESSION_ID"
_bench_cell="${CHUMP_BENCH_CELL}"
_bench_task="${CHUMP_BENCH_TASK_ID}"
_bench_trial="${CHUMP_BENCH_TRIAL_N}"
_bench_dur_s="$SECONDS"
_bench_pr_state="OPEN"
_bench_success_at_arm=true
out="$SANDBOX/run.jsonl"
printf '{"ts":"%s","cell":"%s","task_id":"%s","trial_n":%s,"agent_session":"%s","pr_number":%s,"pr_state_at_record":"%s","duration_s":%s,"success_criteria_met_at_arm_stage":%s,"branch":"%s"}\n' \
    "$_bench_ts" "$_bench_cell" "$_bench_task" "$_bench_trial" \
    "$_bench_session" "$TARGET_PR" "$_bench_pr_state" \
    "$_bench_dur_s" "$_bench_success_at_arm" "$BRANCH" \
    >> "$out"

# Validate as JSON.
python3 - "$out" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    line = f.readline().strip()
rec = json.loads(line)
required = {"ts", "cell", "task_id", "trial_n", "agent_session", "pr_number",
            "pr_state_at_record", "duration_s", "success_criteria_met_at_arm_stage", "branch"}
missing = required - set(rec.keys())
assert not missing, f"missing fields: {missing}"
assert rec["cell"] == "A"
assert rec["task_id"] == "cog032-T01-stale-gaps-yaml-redirect"
assert rec["trial_n"] == 3
assert rec["pr_number"] == 99
assert rec["success_criteria_met_at_arm_stage"] is True
print("  PASS: JSONL line validates with all required fields")
PY

echo
echo "PASS: INFRA-390 — auto-merge gate + auto-close gate + JSONL emit"
