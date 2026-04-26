#!/usr/bin/env bash
# run-study5.sh — COG-018e Study 5: Counterfactual lesson injection via consciousness.
#
# Hypothesis: CHUMP_CONSCIOUSNESS_ENABLED=1 injects lessons_for_context() output
# containing pre-seeded directives with specific arbitrary values (timeouts, keys,
# ports, error codes). Mode A (ON) can cite these values; mode B (OFF) physically
# cannot — the information is not in the prompt or the model's training data.
#
# This is the hardest falsification test. Expected: A pass rate >> B pass rate.
# Any B passes indicate lesson leakage via another mechanism (investigate).
#
# Design:
#   - Pre-seed: study5-counterfactual-lessons.json via --seed-lessons
#   - Fixed: CHUMP_NEUROMOD_ENABLED=1 (neuromod state required for consciousness)
#   - Flag: CHUMP_CONSCIOUSNESS_ENABLED (mode A=1, mode B=0)
#   - Fixture: counterfactual_tasks.json (20 tasks, all require seeded values)
#   - Scoring: LLM judge checks for the specific seeded value in agent output
#
# Usage:
#   scripts/eval/run-study5.sh [--model MODEL] [--limit N] [--dry-run]
#   scripts/eval/run-study5.sh --model meta-llama/Llama-3.3-70B-Instruct-Turbo --limit 5
#
# Env (Together): CHUMP_TOGETHER_CLOUD=1, CHUMP_TOGETHER_JOB_REF, TOGETHER_API_KEY — see docs/operations/TOGETHER_SPEND.md

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

load_env() {
  local f="$1"
  [[ -f "$f" ]] || return
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] && export "$k=$v"
  done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$f" 2>/dev/null) || true
}
load_env "$ROOT/.env"
MAIN_REPO=$(git worktree list --porcelain 2>/dev/null | awk 'NR==1{print $2}')
[[ -n "$MAIN_REPO" && "$MAIN_REPO" != "$ROOT" ]] && load_env "$MAIN_REPO/.env"

FIXTURE="scripts/ab-harness/fixtures/counterfactual_tasks.json"
LESSONS="scripts/ab-harness/fixtures/study5-counterfactual-lessons.json"
CHUMP_BIN="${CHUMP_BIN:-./target/release/chump}"
TAG="study5-counterfactual"
LIMIT=""
DRY_RUN=0
MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)   MODEL="$2"; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "ERROR: $CHUMP_BIN not executable. Build: cargo build --release" >&2; exit 2
fi
if [[ ! -f "$FIXTURE" ]]; then
  echo "ERROR: $FIXTURE not found" >&2; exit 2
fi
if [[ ! -f "$LESSONS" ]]; then
  echo "ERROR: $LESSONS not found" >&2; exit 2
fi

# shellcheck source=scripts/lib/together-study-inference.sh
source "${ROOT}/scripts/lib/together-study-inference.sh"
together_study_inference_or_exit study5 || exit $?

export CHUMP_NEUROMOD_ENABLED=1
export CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=6
# Disable ask_jeff so mode A must answer from injected consciousness context.
# Without this, the model calls ask_jeff for both modes (making them identical).
export CHUMP_DISABLE_ASK_JEFF=1

TS="$(date +%s)"
OUT_DIR="$ROOT/logs/ab"
mkdir -p "$OUT_DIR"

echo "[study5] $(date -u +%H:%M:%S) start"
echo "[study5] fixture=$FIXTURE"
echo "[study5] lessons=$LESSONS"
echo "[study5] tag=$TAG  flag=CHUMP_CONSCIOUSNESS_ENABLED  A=1(on) B=0(off)"
echo "[study5] model=$OPENAI_MODEL @ ${OPENAI_API_BASE}"
echo "[study5] neuromod fixed: CHUMP_NEUROMOD_ENABLED=1"
echo "[study5] ask_jeff disabled: CHUMP_DISABLE_ASK_JEFF=1 (forces model to answer from injected context)"
echo "[study5] order=random (prevents A/B position bias)"
echo ""
echo "[study5] KEY: mode B CANNOT know the seeded values. Any B passes = leak investigation needed."
echo "[study5] Expected direction: A pass rate >> B pass rate."
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[study5] DRY RUN — would call:"
  echo "  scripts/ab-harness/run.sh \\"
  echo "    --fixture $FIXTURE \\"
  echo "    --flag CHUMP_CONSCIOUSNESS_ENABLED \\"
  echo "    --tag $TAG \\"
  echo "    --seed-lessons $LESSONS \\"
  echo "    --order random \\"
  echo "    --chump-bin $CHUMP_BIN${LIMIT:+ \\
    --limit $LIMIT}"
  echo ""
  echo "[study5] DRY RUN done."
  exit 0
fi

LIMIT_ARG=""
[[ -n "$LIMIT" ]] && LIMIT_ARG="--limit $LIMIT"

scripts/ab-harness/run.sh \
  --fixture "$FIXTURE" \
  --flag CHUMP_CONSCIOUSNESS_ENABLED \
  --tag "$TAG" \
  --seed-lessons "$LESSONS" \
  --order random \
  --chump-bin "$CHUMP_BIN" \
  ${LIMIT_ARG}

JSONL=$(ls -t "$OUT_DIR/${TAG}-"*.jsonl 2>/dev/null | grep -v '\.summary\.jsonl' | head -1 || true)
if [[ -z "$JSONL" ]]; then
  echo "[study5] ERROR: no trials JSONL found in $OUT_DIR" >&2; exit 1
fi

echo ""
echo "[study5] $(date -u +%H:%M:%S) trials written: $JSONL"
echo "[study5] scoring..."

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge-claude "claude-sonnet-4-6" || \
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
else
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
fi

SUMMARY=$(ls -t "$OUT_DIR/${TAG}-"*.summary.json 2>/dev/null | head -1 || true)
echo ""
echo "[study5] $(date -u +%H:%M:%S) done."
echo "[study5] summary → ${SUMMARY:-<not found>}"
echo ""
echo "Key result: A pass rate should be much higher than B."
echo "  jq '.by_mode' '${SUMMARY}'"
echo ""
echo "If delta ≈ 0: consciousness injection is not reaching the model."
echo "If A >> B:    counterfactual lessons are being injected and used."
echo "If B > 0:     investigate — seeded values should be unreachable without injection."
echo ""
echo "Per-category breakdown:"
echo "  jq '.by_category' '${SUMMARY}'"
