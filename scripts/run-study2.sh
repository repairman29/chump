#!/usr/bin/env bash
# run-study2.sh — COG-018b Study 2: Consciousness framework effect on belief-guided tool selection.
#
# Hypothesis: CHUMP_CONSCIOUSNESS_ENABLED=1 injects a formatted belief-state summary
# ("Least certain: run_cli(rel~0.55, unc~0.30)") before the agent answers. This
# formatted signal should increase read_file selection rate vs mode B (OFF), where
# the agent must infer tool reliability from raw tool-call history alone.
#
# Design:
#   - Fixed: CHUMP_NEUROMOD_ENABLED=1 (so belief state actually accumulates)
#   - Flag:  CHUMP_CONSCIOUSNESS_ENABLED (mode A=1, mode B=0)
#   - Fixture: warm_consciousness_tasks.json (25 tasks with 3-fail-run_cli / 2-succeed-read_file preambles)
#   - Order: random (prevent position effects)
#   - Measurement: agent uses read_file for final question (scored by LLM judge)
#
# Usage:
#   scripts/run-study2.sh [--model MODEL] [--limit N] [--dry-run]
#   scripts/run-study2.sh --model meta-llama/Llama-3.3-70B-Instruct-Turbo --limit 10
#
# Env:
#   TOGETHER_API_KEY        Only used when CHUMP_TOGETHER_CLOUD=1 (see docs/TOGETHER_SPEND.md)
#   CHUMP_TOGETHER_CLOUD=1  Opt-in: route the binary to Together serverless (paid)
#   CHUMP_TOGETHER_JOB_REF  Budget ticket — required with CLOUD=1
#   OPENAI_API_BASE         From .env when not using Together cloud
#   CHUMP_BIN               Path to chump binary (default: ./target/release/chump)

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

FIXTURE="scripts/ab-harness/fixtures/warm_consciousness_tasks.json"
CHUMP_BIN="${CHUMP_BIN:-./target/release/chump}"
TAG="study2-consciousness"
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

# shellcheck source=scripts/lib/together-study-inference.sh
source "${ROOT}/scripts/lib/together-study-inference.sh"
together_study_inference_or_exit study2 || exit $?

# Study 2 fixed env: neuromod ON so belief state updates happen per tool call.
export CHUMP_NEUROMOD_ENABLED=1
# Allow the full preamble cascade (3 fails + 2 succeeds) before abort guard fires.
export CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=6

TS="$(date +%s)"
OUT_DIR="$ROOT/logs/ab"
mkdir -p "$OUT_DIR"

echo "[study2] $(date -u +%H:%M:%S) start"
echo "[study2] fixture=$FIXTURE"
echo "[study2] tag=$TAG  flag=CHUMP_CONSCIOUSNESS_ENABLED  A=1(on) B=0(off)"
echo "[study2] model=$OPENAI_MODEL @ ${OPENAI_API_BASE}"
echo "[study2] neuromod fixed: CHUMP_NEUROMOD_ENABLED=1"
echo "[study2] order=random (prevents A/B position bias)"
echo ""
echo "[study2] NOTE: Each task preamble runs 3 failing chump-study-* commands then"
echo "[study2]       reads 2 real repo files. The measurement question is answerable"
echo "[study2]       by either tool; mode A gets the belief-state injection."
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[study2] DRY RUN — would call:"
  echo "  scripts/ab-harness/run.sh \\"
  echo "    --fixture $FIXTURE \\"
  echo "    --flag CHUMP_CONSCIOUSNESS_ENABLED \\"
  echo "    --tag $TAG \\"
  echo "    --order random \\"
  echo "    --chump-bin $CHUMP_BIN${LIMIT:+ \\
    --limit $LIMIT}"
  echo ""
  echo "[study2] DRY RUN done."
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
  echo "[study2] ERROR: no trials JSONL found in $OUT_DIR" >&2; exit 1
fi

echo ""
echo "[study2] $(date -u +%H:%M:%S) trials written: $JSONL"

# Optional manipulation check: for mode A (consciousness ON), verify DA deviated.
# This confirms the neuromod preamble actually fired within the invocation.
echo "[study2] running manipulation check (verifying preamble cascade fired)..."
echo ""
if scripts/ab-harness/validate_manipulation.py "$JSONL" "$FIXTURE" --report; then
  echo ""
  echo "[study2] manipulation check passed — proceeding to scoring"
else
  echo ""
  echo "[study2] WARNING: some preambles may not have fired — check telemetry"
  echo "[study2] Continuing to score anyway (failures may still be informative)"
fi

echo ""
echo "[study2] $(date -u +%H:%M:%S) scoring..."
# Study 2 scoring is semantic: did the agent use read_file for the final question?
# The LLM judge reads expected_properties Custom strings to check this.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge-claude "claude-sonnet-4-6" || \
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
else
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
fi

SUMMARY=$(ls -t "$OUT_DIR/${TAG}-"*.summary.json 2>/dev/null | head -1 || true)
echo ""
echo "[study2] $(date -u +%H:%M:%S) done."
echo "[study2] summary → ${SUMMARY:-<not found>}"
echo ""
echo "Key result: compare mode A (consciousness ON) vs B (OFF) pass rate."
echo "  jq '.by_mode' '${SUMMARY}'"
echo ""
echo "If A pass rate > B pass rate, consciousness injection steers tool selection."
echo "Recommend: repeat with a second model to check if effect is model-specific."
