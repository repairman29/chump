#!/usr/bin/env bash
# run-study1.sh — COG-018a Study 1: Neuromodulation effect on failure-cascade recovery.
#
# Hypothesis: CHUMP_NEUROMOD_ENABLED=1 shifts the agent to Explore regime
# (tool_budget=8) and injects belief-state context after repeated tool failures.
# This should produce measurably different recovery strategies vs NEUROMOD=0.
#
# Design:
#   - Fixed: CHUMP_CONSCIOUSNESS_ENABLED=1 (so the model can see state summaries)
#   - Flag:  CHUMP_NEUROMOD_ENABLED (mode A=1, mode B=0)
#   - Fixture: warm_neuromod_tasks.json (30 tasks with embedded failure cascades)
#   - Order: random (prevent position effects)
#   - Manipulation check: validate_manipulation.py confirms DA deviated >0.05
#
# Usage:
#   scripts/run-study1.sh [--model MODEL] [--limit N] [--dry-run]
#   scripts/run-study1.sh --model meta-llama/Llama-3.3-70B-Instruct-Turbo --limit 10
#
# Env:
#   TOGETHER_API_KEY   Required for Together.ai cloud inference (recommended)
#   OPENAI_API_BASE    Set automatically to Together.ai; override to use Ollama
#   OPENAI_MODEL       Set automatically; override to use a different model
#   CHUMP_BIN          Path to chump binary (default: ./target/release/chump)

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
# Check worktree .env first, then main repo .env (worktrees share secrets with parent).
load_env "$ROOT/.env"
# Also check the main repo root (worktrees share secrets with the parent).
MAIN_REPO=$(git worktree list --porcelain 2>/dev/null | awk 'NR==1{print $2}')
[[ -n "$MAIN_REPO" && "$MAIN_REPO" != "$ROOT" ]] && load_env "$MAIN_REPO/.env"

FIXTURE="scripts/ab-harness/fixtures/warm_neuromod_tasks.json"
CHUMP_BIN="${CHUMP_BIN:-./target/release/chump}"
TAG="study1-neuromod"
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

# Configure inference endpoint.
# Together.ai takes priority when TOGETHER_API_KEY is set — even if OPENAI_API_BASE
# is already set in .env (which defaults to the local MLX endpoint).
if [[ -n "${TOGETHER_API_KEY:-}" ]]; then
  export OPENAI_API_BASE="https://api.together.xyz/v1"
  export OPENAI_API_KEY="${TOGETHER_API_KEY}"
  export OPENAI_MODEL="${MODEL:-meta-llama/Llama-3.3-70B-Instruct-Turbo}"
  echo "[study1] using Together.ai model: $OPENAI_MODEL"
elif [[ -z "${OPENAI_API_BASE:-}" ]]; then
  if curl -sf --connect-timeout 2 "http://127.0.0.1:11434/v1/models" >/dev/null 2>&1; then
    export OPENAI_API_BASE="http://127.0.0.1:11434/v1"
    export OPENAI_API_KEY="ollama"
    export OPENAI_MODEL="${MODEL:-qwen2.5:7b}"
    echo "[study1] using Ollama model: $OPENAI_MODEL"
  else
    echo "ERROR: No inference endpoint. Set TOGETHER_API_KEY or start Ollama." >&2; exit 3
  fi
else
  [[ -n "$MODEL" ]] && export OPENAI_MODEL="$MODEL"
  echo "[study1] using existing endpoint: $OPENAI_MODEL @ $OPENAI_API_BASE"
fi

# Study 1 fixed env: consciousness ON so agent can see the state summaries.
export CHUMP_CONSCIOUSNESS_ENABLED=1
# Allow the full failure cascade to play out before the abort guard fires.
# Default is 3 consecutive failures → abort; our tasks require 4-5.
export CHUMP_MAX_CONSECUTIVE_TOOL_FAILS=6

TS="$(date +%s)"
OUT_DIR="$ROOT/logs/ab"
mkdir -p "$OUT_DIR"

echo "[study1] $(date -u +%H:%M:%S) start"
echo "[study1] fixture=$FIXTURE"
echo "[study1] tag=$TAG  flag=CHUMP_NEUROMOD_ENABLED  A=1(on) B=0(off)"
echo "[study1] model=$OPENAI_MODEL @ ${OPENAI_API_BASE}"
echo "[study1] consciousness fixed: CHUMP_CONSCIOUSNESS_ENABLED=1"
echo "[study1] order=random (prevents A/B position bias)"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[study1] DRY RUN — would call:"
  echo "  scripts/ab-harness/run.sh \\"
  echo "    --fixture $FIXTURE \\"
  echo "    --flag CHUMP_NEUROMOD_ENABLED \\"
  echo "    --tag $TAG \\"
  echo "    --order random \\"
  echo "    --chump-bin $CHUMP_BIN${LIMIT:+ \\
    --limit $LIMIT}"
  echo ""
  echo "[study1] DRY RUN done."
  exit 0
fi

LIMIT_ARG=""
[[ -n "$LIMIT" ]] && LIMIT_ARG="--limit $LIMIT"

scripts/ab-harness/run.sh \
  --fixture "$FIXTURE" \
  --flag CHUMP_NEUROMOD_ENABLED \
  --tag "$TAG" \
  --order random \
  --chump-bin "$CHUMP_BIN" \
  ${LIMIT_ARG}

# Find the just-written JSONL.
JSONL=$(ls -t "$OUT_DIR/${TAG}-"*.jsonl 2>/dev/null | grep -v '\.summary\.jsonl' | head -1 || true)
if [[ -z "$JSONL" ]]; then
  echo "[study1] ERROR: no trials JSONL found in $OUT_DIR" >&2; exit 1
fi

echo ""
echo "[study1] $(date -u +%H:%M:%S) trials written: $JSONL"
echo "[study1] running manipulation check..."
echo ""

# Manipulation check: confirm DA deviated >0.05 after failure_cascade tasks.
# Exits 1 if manipulation failures found; run with --exclude-failed to clean.
if scripts/ab-harness/validate_manipulation.py "$JSONL" "$FIXTURE" --report; then
  echo ""
  echo "[study1] manipulation check passed — proceeding to scoring"
else
  echo ""
  echo "[study1] WARNING: manipulation failures found — producing clean subset"
  scripts/ab-harness/validate_manipulation.py "$JSONL" "$FIXTURE" --exclude-failed || true
  JSONL="${JSONL%.jsonl}.manipulation-passed.jsonl"
  echo "[study1] scoring clean subset: $JSONL"
fi

echo ""
echo "[study1] $(date -u +%H:%M:%S) scoring..."
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge-claude "claude-sonnet-4-6" || \
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
else
  scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
fi

SUMMARY=$(ls -t "$OUT_DIR/${TAG}-"*.summary.json 2>/dev/null | head -1 || true)
echo ""
echo "[study1] $(date -u +%H:%M:%S) done."
echo "[study1] summary → ${SUMMARY:-<not found>}"
echo ""
echo "Next: compare mode A vs B pass rates in the summary."
echo "  jq '.by_mode' '${SUMMARY}'"
