#!/usr/bin/env bash
# run-study3.sh — Study 3: Precision controller budget warning effect on task completion.
#
# Hypothesis: CHUMP_CONSCIOUSNESS_ENABLED=1 (mode A) makes the agent stop earlier on
# multi-file tasks because the budget-exceeded warning ("Tool call budget exceeded: N
# calls this turn (regime recommends max M). Consider wrapping up.") reaches the model
# context via the blackboard. Mode B (consciousness OFF) never sees the warning and
# reads all required files, so it passes MORE often on tasks that legitimately need
# more tool calls than the regime budget allows.
#
# Expected direction: A < B pass rate on budget_exceeded tasks.
# This is a DIRECT FALSIFICATION TEST: consciousness should hurt performance here.
# If A >= B on budget_exceeded tasks, the budget-warning channel has no effect.
#
# Design:
#   - Fixed: CHUMP_NEUROMOD_ENABLED=1 (so regime tracking is live)
#   - Fixed: CHUMP_ADAPTIVE_REGIMES=1 (enables adaptive regime tracking)
#   - Fixed: CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=8 (let agent attempt all reads;
#            budget warning is not a tool failure — don't let the abort guard fire early)
#   - Flag:  CHUMP_CONSCIOUSNESS_ENABLED (mode A=1, mode B=0)
#   - Fixture: precision_controller_tasks.json (20 tasks across 3 depth categories)
#   - Order: random (prevent position effects)
#   - Measurement: agent provides complete answers for ALL required files per task
#
# Task categories:
#   control_shallow  (5 tasks, required_reads=2-3): both modes should pass
#   budget_boundary  (10 tasks, required_reads=4-5): tests Balanced regime limit (max=5)
#   budget_exceeded  (5 tasks, required_reads=6-7): definitely over Balanced budget
#
# Usage:
#   scripts/eval/run-study3.sh [--model MODEL] [--limit N] [--dry-run]
#   scripts/eval/run-study3.sh --model meta-llama/Llama-3.3-70B-Instruct-Turbo --limit 10
#
# Env:
#   TOGETHER_API_KEY        Only used when CHUMP_TOGETHER_CLOUD=1 (see docs/operations/TOGETHER_SPEND.md)
#   CHUMP_TOGETHER_CLOUD=1  Opt-in: route the binary to Together serverless (paid)
#   CHUMP_TOGETHER_JOB_REF  Budget ticket — required with CLOUD=1
#   OPENAI_API_BASE         From .env when not using Together cloud
#   CHUMP_BIN               Path to chump binary (default: ./target/release/chump)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

load_env() {
  local f="$1"
  [[ -f "$f" ]] || return
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] && export "$k=$v"
  done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$f" 2>/dev/null) || true
}
# Check worktree .env first, then main repo .env (worktrees share secrets with parent).
load_env "$ROOT/.env"
# Also check the main repo root (worktrees share secrets with the parent).
MAIN_REPO=$(git worktree list --porcelain 2>/dev/null | awk 'NR==1{print $2}')
[[ -n "$MAIN_REPO" && "$MAIN_REPO" != "$ROOT" ]] && load_env "$MAIN_REPO/.env"

FIXTURE="scripts/ab-harness/fixtures/precision_controller_tasks.json"
CHUMP_BIN="${CHUMP_BIN:-./target/release/chump}"
TAG="study3-precision"
LIMIT=""
DRY_RUN=0
MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)   MODEL="$2"; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "ERROR: $CHUMP_BIN not executable. Build: cargo build --release" >&2; exit 2
fi
if [[ ! -f "$FIXTURE" ]]; then
  echo "ERROR: $FIXTURE not found" >&2; exit 2
fi

# shellcheck source=scripts/lib/together-study-inference.sh
source "${ROOT}/scripts/lib/together-study-inference.sh"
together_study_inference_or_exit study3 || exit $?

# Study 3 fixed env: neuromod ON so regime tracking is live.
export CHUMP_NEUROMOD_ENABLED=1
# Adaptive regime tracking: regime shifts based on tool call history.
export CHUMP_ADAPTIVE_REGIMES=1
# Allow the agent to attempt all required reads; the budget warning is delivered via
# the consciousness channel (the variable under test), NOT as a tool failure.
# We want the abort guard to stay out of the way so only the consciousness signal differs.
export CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=8

TS="$(date +%s)"
OUT_DIR="$ROOT/logs/ab"
mkdir -p "$OUT_DIR"

echo "[study3] $(date -u +%H:%M:%S) start"
echo "[study3] fixture=$FIXTURE"
echo "[study3] tag=$TAG  flag=CHUMP_CONSCIOUSNESS_ENABLED  A=1(on) B=0(off)"
echo "[study3] model=$OPENAI_MODEL @ ${OPENAI_API_BASE}"
echo "[study3] fixed: CHUMP_NEUROMOD_ENABLED=1  CHUMP_ADAPTIVE_REGIMES=1"
echo "[study3] fixed: CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=8 (let agent attempt all reads)"
echo "[study3] order=random (prevents A/B position bias)"
echo ""
echo "[study3] NOTE: Expected direction is A < B on budget_exceeded tasks."
echo "[study3]       Mode A (consciousness ON) sees the budget-exceeded warning and"
echo "[study3]       stops early. Mode B (consciousness OFF) reads all required files."
echo "[study3]       If A >= B on budget_exceeded, the warning channel has no effect."
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[study3] DRY RUN — would call:"
  echo "  scripts/ab-harness/run.sh \\"
  echo "    --fixture $FIXTURE \\"
  echo "    --flag CHUMP_CONSCIOUSNESS_ENABLED \\"
  echo "    --tag $TAG \\"
  echo "    --order random \\"
  echo "    --chump-bin $CHUMP_BIN${LIMIT:+ \\
    --limit $LIMIT}"
  echo ""
  echo "[study3] DRY RUN done."
  exit 0
fi

LIMIT_ARG=""
[[ -n "$LIMIT" ]] && LIMIT_ARG="--limit $LIMIT"

scripts/ab-harness/run.sh \
  --fixture "$FIXTURE" \
  --flag CHUMP_CONSCIOUSNESS_ENABLED \
  --tag "$TAG" \
  --order random \
  --chump-bin "$CHUMP_BIN" \
  ${LIMIT_ARG}

# Find the just-written JSONL.
JSONL=$(ls -t "$OUT_DIR/${TAG}-"*.jsonl 2>/dev/null | grep -v '\.summary\.jsonl' | head -1 || true)
if [[ -z "$JSONL" ]]; then
  echo "[study3] ERROR: no trials JSONL found in $OUT_DIR" >&2; exit 1
fi

echo ""
echo "[study3] $(date -u +%H:%M:%S) trials written: $JSONL"
echo "[study3] running manipulation check..."
echo ""

# Manipulation check: confirm the agent actually attempted the required reads in each
# trial. Trials where the agent made fewer tool calls than required_reads are excluded
# as manipulation failures (abort guard fired before budget warning could take effect).
if scripts/ab-harness/validate_manipulation.py "$JSONL" "$FIXTURE" --report; then
  echo ""
  echo "[study3] manipulation check passed — proceeding to scoring"
else
  echo ""
  echo "[study3] WARNING: manipulation failures found — producing clean subset"
  scripts/ab-harness/validate_manipulation.py "$JSONL" "$FIXTURE" --exclude-failed || true
  JSONL="${JSONL%.jsonl}.manipulation-passed.jsonl"
  echo "[study3] scoring clean subset: $JSONL"
fi

echo ""
echo "[study3] $(date -u +%H:%M:%S) scoring..."
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge-claude "claude-sonnet-4-6" || \
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
else
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
fi

SUMMARY=$(ls -t "$OUT_DIR/${TAG}-"*.summary.json 2>/dev/null | head -1 || true)
echo ""
echo "[study3] $(date -u +%H:%M:%S) done."
echo "[study3] summary → ${SUMMARY:-<not found>}"
echo ""
echo "Key result: compare mode A vs B pass rates split by category."
echo "  jq '.by_mode' '${SUMMARY}'"
echo "  jq '.by_category' '${SUMMARY}'"
echo ""
echo "EXPECTED DIRECTION (confirmation signal):"
echo "  control_shallow:  A ≈ B  (budget not reached; no warning fires)"
echo "  budget_boundary:  A <= B (warning may fire at depth 5+)"
echo "  budget_exceeded:  A < B  (warning fires; mode A stops early)"
echo ""
echo "If A < B on budget_exceeded tasks, the consciousness channel carries the"
echo "budget warning and measurably shortens task completion."
echo "If A >= B on budget_exceeded tasks, the warning has no behavioral effect."
echo ""
echo "Recommend: repeat with a second model to check if effect is model-specific."
