#!/usr/bin/env bash
# COG-006 gate runner — neuromodulation A/B harness.
#
# Wraps scripts/ab-harness/run.sh with the COG-006 fixture and flag, then
# runs score.py and the COG-006 gate evaluator.  Exit 0 = gate passed,
# exit 1 = gate failed, exit 2 = usage/config error.
#
# Usage:
#   scripts/ab-harness/run-cog006-neuromod.sh [--limit N] [--chump-bin PATH]
#       [--judge MODEL] [--judge-claude MODEL] [--resume <existing>.jsonl]
#       [--order fixed|reverse|random] [--dry-run]
#
# Examples:
#   # Full 50-trial run (25 tasks × 2 modes):
#   scripts/ab-harness/run-cog006-neuromod.sh
#
#   # Quick smoke test (5 tasks only):
#   scripts/ab-harness/run-cog006-neuromod.sh --limit 5
#
#   # With Claude as independent judge:
#   scripts/ab-harness/run-cog006-neuromod.sh --judge-claude claude-haiku-4-5
#
#   # Score an existing run (skip the trial step):
#   scripts/ab-harness/run-cog006-neuromod.sh --resume logs/ab/cog-006-neuromod-ab-1234567890.jsonl
#
# Gate criteria (Section 3.3 of docs/strategy/CHUMP_TO_CHAMP.md):
#   PASS: delta_by_category["dynamic"] >= 0 (neuromod doesn't hurt dynamic tasks)
#         AND abs(delta_by_category["trivial"]) < 0.15 (trivial tasks unaffected)
#   FAIL: neuromod hurts dynamic task success rate
#
# The gate is intentionally conservative — we require neuromod to not regress,
# not that it must improve by a fixed margin.  Improvement is reported and
# documented but is not a binary gate; this avoids flip-flopping on small N
# with structural (non-judge) scoring.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$ROOT/scripts/ab-harness/fixtures/neuromod_tasks.json"
FLAG="CHUMP_NEUROMOD_ENABLED"
TAG="cog-006-neuromod-ab"
HARNESS="$ROOT/scripts/ab-harness/run.sh"
SCORER="$ROOT/scripts/ab-harness/score.py"
GATE="$ROOT/scripts/ab-harness/score-cog006.py"

LIMIT=""
CHUMP_BIN="$ROOT/target/release/chump"
RESUME=""
ORDER="fixed"
JUDGE=""
JUDGE_CLAUDE=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)      LIMIT="--limit $2"; shift 2;;
    --chump-bin)  CHUMP_BIN="$2"; shift 2;;
    --resume)     RESUME="$2"; shift 2;;
    --order)      ORDER="$2"; shift 2;;
    --judge)      JUDGE="$2"; shift 2;;
    --judge-claude) JUDGE_CLAUDE="$2"; shift 2;;
    --dry-run)    DRY_RUN=1; shift;;
    -h|--help)    sed -n '2,42p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ ! -f "$FIXTURE" ]]; then
  echo "ERROR: fixture not found: $FIXTURE" >&2
  exit 2
fi
if [[ ! -f "$HARNESS" ]]; then
  echo "ERROR: harness not found: $HARNESS" >&2
  exit 2
fi
if [[ ! -f "$SCORER" ]]; then
  echo "ERROR: scorer not found: $SCORER" >&2
  exit 2
fi
if [[ ! -f "$GATE" ]]; then
  echo "ERROR: gate script not found: $GATE" >&2
  exit 2
fi

echo "=== COG-006 Neuromodulation A/B gate ==="
echo "fixture : $FIXTURE"
echo "flag    : $FLAG (A=1=neuromod_enabled, B=0=baseline)"
echo "tag     : $TAG"
echo ""

# ── 1. Run the trials (or skip if --resume) ──────────────────────────────────
if [[ -n "$RESUME" ]]; then
  TRIALS="$RESUME"
  echo "[cog-006] resuming from: $TRIALS"
elif [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[cog-006] --dry-run: skipping trial execution"
  echo "[cog-006] would run: $HARNESS --fixture $FIXTURE --flag $FLAG --tag $TAG --order $ORDER ${LIMIT:-}"
  exit 0
else
  # shellcheck disable=SC2086
  bash "$HARNESS" \
    --fixture "$FIXTURE" \
    --flag "$FLAG" \
    --tag "$TAG" \
    --chump-bin "$CHUMP_BIN" \
    --order "$ORDER" \
    ${LIMIT:-}

  # Harness writes to logs/ab/<tag>-<ts>.jsonl; find the newest one.
  TRIALS="$(ls -t "$ROOT/logs/ab/${TAG}"-*.jsonl 2>/dev/null | head -1)"
  if [[ -z "$TRIALS" ]]; then
    echo "ERROR: no trials file produced under logs/ab/${TAG}-*.jsonl" >&2
    exit 1
  fi
fi

echo ""
echo "=== Trials: $TRIALS ==="

# ── 2. Score the trials ───────────────────────────────────────────────────────
JUDGE_ARGS=()
if [[ -n "$JUDGE_CLAUDE" ]]; then
  JUDGE_ARGS+=("--judge-claude" "$JUDGE_CLAUDE")
elif [[ -n "$JUDGE" ]]; then
  JUDGE_ARGS+=("--judge" "$JUDGE")
fi

python3.12 "$SCORER" "$TRIALS" "$FIXTURE" "${JUDGE_ARGS[@]:-}"

# score.py writes <trials>.summary.json
SUMMARY="${TRIALS%.jsonl}.summary.json"
if [[ ! -f "$SUMMARY" ]]; then
  # score.py uses Path.with_suffix so if TRIALS already ends in .jsonl:
  SUMMARY="${TRIALS%.*}.summary.json"
fi
if [[ ! -f "$SUMMARY" ]]; then
  echo "ERROR: summary not found after scoring (looked for $SUMMARY)" >&2
  exit 1
fi

echo ""
echo "=== COG-006 Section 3.3 gate evaluation ==="

# ── 3. Evaluate the Section 3.3 gate ─────────────────────────────────────────
python3.12 "$GATE" "$SUMMARY"
GATE_EXIT=$?

if [[ "$GATE_EXIT" -eq 0 ]]; then
  echo ""
  echo "✓ COG-006 gate PASSED"
  echo "  Results: $SUMMARY"
  echo "  docs/strategy/CHUMP_TO_CHAMP.md §3.3 gate criterion satisfied."
  exit 0
else
  echo ""
  echo "✗ COG-006 gate FAILED (exit $GATE_EXIT)"
  echo "  Results: $SUMMARY"
  echo "  Review the summary, inspect $TRIALS for per-trial diagnostics."
  exit 1
fi
