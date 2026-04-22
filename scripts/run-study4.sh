#!/usr/bin/env bash
# run-study4.sh — Study 4: Injection Readability — consciousness injection effect on reliability attribution.
#
# Hypothesis: CHUMP_CONSCIOUSNESS_ENABLED=1 injects a formatted belief-state summary
# ("Belief state: trajectory=0.55, freshness=0.85, Least certain: run_cli(rel=0.55,unc=0.300)")
# before the agent answers an explicit tool-reliability question. Mode A agents should cite
# NUMERICAL reliability scores matching the belief state (run_cli ~5/10, read_file ~9/10,
# citing "reliability=0.55"). Mode B (OFF) will still correctly rank run_cli lower from
# raw failure history but give QUALITATIVE reasoning rather than numbers.
# Both modes should correctly rank run_cli < read_file — the key difference is
# quantitative vs qualitative attribution.
#
# Design:
#   - Fixed: CHUMP_NEUROMOD_ENABLED=1 (so belief state actually accumulates per tool call)
#   - Fixed: CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=6 (allows full 3-fail preamble to run)
#   - Flag:  CHUMP_CONSCIOUSNESS_ENABLED (mode A=1/ON, mode B=0/OFF)
#   - Fixture: injection_readability_tasks.json (20 tasks: 10 reliability_rating + 10 selection_justified)
#   - Order: random (prevent A/B position bias)
#   - Measurement:
#       reliability_rating tasks: agent cites specific numerical scores + correct ranking
#       selection_justified tasks: agent chooses read_file + justifies with specific reliability reasoning
#
# Usage:
#   scripts/run-study4.sh [--model MODEL] [--limit N] [--dry-run]
#   scripts/run-study4.sh --model meta-llama/Llama-3.3-70B-Instruct-Turbo --limit 10
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

FIXTURE="scripts/ab-harness/fixtures/injection_readability_tasks.json"
CHUMP_BIN="${CHUMP_BIN:-./target/release/chump}"
TAG="study4-injection-readability"
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
together_study_inference_or_exit study4 || exit $?

# Study 4 fixed env: neuromod ON so belief state updates per tool call.
export CHUMP_NEUROMOD_ENABLED=1
# Allow the full preamble cascade (3 fails + 2 succeeds) before abort guard fires.
export CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=6

TS="$(date +%s)"
OUT_DIR="$ROOT/logs/ab"
mkdir -p "$OUT_DIR"

echo "[study4] $(date -u +%H:%M:%S) start"
echo "[study4] fixture=$FIXTURE"
echo "[study4] tag=$TAG  flag=CHUMP_CONSCIOUSNESS_ENABLED  A=1(on) B=0(off)"
echo "[study4] model=$OPENAI_MODEL @ ${OPENAI_API_BASE}"
echo "[study4] neuromod fixed: CHUMP_NEUROMOD_ENABLED=1"
echo "[study4] tool-fail guard fixed: CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=6"
echo "[study4] order=random (prevents A/B position bias)"
echo ""
echo "[study4] NOTE: Mode A gets the formatted belief state injection:"
echo "[study4]   'Belief state: trajectory=0.55, freshness=0.85, Least certain: run_cli(rel=0.55,unc=0.300)'"
echo "[study4] Mode A should give NUMERICAL reliability scores (run_cli ~5/10, read_file ~9/10)."
echo "[study4] Mode B should give qualitative reasoning ('commands all failed', 'file reads succeeded')."
echo "[study4] Both modes should correctly rank run_cli < read_file."
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[study4] DRY RUN — would call:"
  echo "  scripts/ab-harness/run.sh \\"
  echo "    --fixture $FIXTURE \\"
  echo "    --flag CHUMP_CONSCIOUSNESS_ENABLED \\"
  echo "    --tag $TAG \\"
  echo "    --order random \\"
  echo "    --chump-bin $CHUMP_BIN${LIMIT:+ \\
    --limit $LIMIT}"
  echo ""
  echo "[study4] DRY RUN done."
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
  echo "[study4] ERROR: no trials JSONL found in $OUT_DIR" >&2; exit 1
fi

echo ""
echo "[study4] $(date -u +%H:%M:%S) trials written: $JSONL"

# Manipulation check: verify preamble cascade fired and belief state was updated.
# For mode A trials, also check that the injection string appeared in context.
echo "[study4] running manipulation check (verifying preamble cascade fired)..."
echo ""
if scripts/ab-harness/validate_manipulation.py "$JSONL" "$FIXTURE" --report; then
  echo ""
  echo "[study4] manipulation check passed — proceeding to scoring"
else
  echo ""
  echo "[study4] WARNING: some preambles may not have fired — check telemetry"
  echo "[study4] Continuing to score anyway (partial failures may still be informative)"
fi

echo ""
echo "[study4] $(date -u +%H:%M:%S) scoring..."
# Study 4 scoring is semantic: did the agent produce specific numerical reliability scores,
# rank run_cli lower than read_file, and (for selection_justified tasks) choose read_file?
# The LLM judge reads expected_properties Custom strings to evaluate these criteria.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge-claude "claude-sonnet-4-6" || \
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
else
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
fi

SUMMARY=$(ls -t "$OUT_DIR/${TAG}-"*.summary.json 2>/dev/null | head -1 || true)
echo ""
echo "[study4] $(date -u +%H:%M:%S) done."
echo "[study4] summary → ${SUMMARY:-<not found>}"
echo ""
echo "Key result: compare mode A (consciousness ON) vs B (OFF) on numerical attribution."
echo "  jq '.by_mode' '${SUMMARY}'"
echo ""
echo "Primary finding: if mode A pass rate > mode B pass rate on reliability_rating tasks,"
echo "the consciousness injection is producing measurably more quantitative responses."
echo "Secondary check: selection_justified tasks — both modes should choose read_file,"
echo "but mode A justifications should cite numeric scores while mode B cites raw history."
echo ""
echo "Recommend: cross-check with a second model to determine if effect is model-specific."
