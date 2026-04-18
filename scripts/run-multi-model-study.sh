#!/usr/bin/env bash
# run-multi-model-study.sh — COG-001 round-2 driver.
#
# COG-001 acceptance: "scripts/run-consciousness-study.sh produces a results JSON
# with per-model LLM-judge scores; paper section 4 is auto-populated with real
# data; latency overhead per model size is tabulated."
#
# This script is the round-2 driver: same fixture under each model in MODELS,
# with CHUMP_CONSCIOUSNESS_ENABLED toggled, judge-scored via
# scripts/ab-harness/score.py --judge.
#
# Multi-day compute envelope. Run unattended. Resumes idempotently — any
# (model, mode) combo whose summary.json already exists is skipped.
#
# Usage:
#   scripts/run-multi-model-study.sh                      # full sweep
#   scripts/run-multi-model-study.sh --dry-run            # preview
#   scripts/run-multi-model-study.sh --models qwen2.5:7b  # single model
#   scripts/run-multi-model-study.sh --fixture <path>     # custom fixture
#
# Env:
#   CHUMP_STUDY_FIXTURE   default scripts/ab-harness/fixtures/reflection_tasks.json
#   CHUMP_STUDY_MODELS    default "qwen2.5:7b qwen3:8b qwen2.5:14b" (space-separated)
#   CHUMP_STUDY_LIMIT     default 20
#   OLLAMA_BASE           default http://127.0.0.1:11434
#   CHUMP_BIN             default ./target/release/chump

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FIXTURE="${CHUMP_STUDY_FIXTURE:-scripts/ab-harness/fixtures/reflection_tasks.json}"
MODELS_DEFAULT="qwen2.5:7b qwen3:8b qwen2.5:14b"
MODELS_STR="${CHUMP_STUDY_MODELS:-$MODELS_DEFAULT}"
LIMIT="${CHUMP_STUDY_LIMIT:-20}"
OLLAMA_BASE="${OLLAMA_BASE:-http://127.0.0.1:11434}"
CHUMP_BIN="${CHUMP_BIN:-./target/release/chump}"

DRY_RUN=0
PARSED_MODELS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --fixture) FIXTURE="$2"; shift 2 ;;
    --models) PARSED_MODELS="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$PARSED_MODELS" ]] && MODELS_STR="$PARSED_MODELS"

# Pre-flight.
if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "ERROR: $CHUMP_BIN not executable. Build: cargo build --release" >&2
  exit 2
fi
if [[ ! -f "$FIXTURE" ]]; then
  echo "ERROR: $FIXTURE not found" >&2
  exit 2
fi
if ! curl -sf --connect-timeout 3 "$OLLAMA_BASE/api/tags" >/dev/null 2>&1; then
  echo "ERROR: ollama not reachable at $OLLAMA_BASE" >&2
  exit 3
fi

OUT_DIR="$ROOT/logs/study"
mkdir -p "$OUT_DIR"
TS="$(date +%s)"
RESULTS_JSON="$OUT_DIR/multi-model-${TS}.json"

echo "[study] $(date -u +%H:%M:%S) start"
echo "[study] fixture=$FIXTURE  limit=$LIMIT"
echo "[study] models: $MODELS_STR"
echo "[study] results → $RESULTS_JSON"
echo

run_one() {
  local model="$1"
  local tag="study-${model//[:.]/-}-$(echo "$FIXTURE" | xargs basename | sed 's/_tasks.json//')"

  # Idempotency: skip if summary already exists.
  local existing
  existing=$(ls "$ROOT/logs/ab/${tag}-"*.summary.json 2>/dev/null | head -1)
  if [[ -n "$existing" ]]; then
    echo "[study] [$model] SKIP — $existing"
    return 0
  fi

  echo "[study] [$model] $(date -u +%H:%M:%S) START"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  would run: scripts/ab-harness/run.sh --fixture $FIXTURE --flag CHUMP_CONSCIOUSNESS_ENABLED --tag $tag --limit $LIMIT --chump-bin $CHUMP_BIN"
    return 0
  fi

  OPENAI_API_BASE="${OLLAMA_BASE}/v1" \
  OPENAI_API_KEY=ollama \
  OPENAI_MODEL="$model" \
  CHUMP_OLLAMA_NUM_CTX=8192 \
  CHUMP_HOME="$ROOT" \
  CHUMP_REPO="$ROOT" \
    scripts/ab-harness/run.sh \
      --fixture "$FIXTURE" \
      --flag CHUMP_CONSCIOUSNESS_ENABLED \
      --tag "$tag" \
      --limit "$LIMIT" \
      --chump-bin "$CHUMP_BIN" || {
    echo "[study] [$model] FAIL — harness exited nonzero" >&2
    return 1
  }

  local jsonl
  jsonl=$(ls -t "$ROOT/logs/ab/${tag}-"*.jsonl 2>/dev/null | head -1)
  [[ -z "$jsonl" ]] && { echo "[study] [$model] FAIL — no jsonl"; return 1; }

  echo "[study] [$model] $(date -u +%H:%M:%S) scoring..."
  scripts/ab-harness/score.py "$jsonl" "$FIXTURE" --judge "$model" || {
    echo "[study] [$model] WARN — judge failed, structural only" >&2
    scripts/ab-harness/score.py "$jsonl" "$FIXTURE" || return 1
  }

  echo "[study] [$model] $(date -u +%H:%M:%S) DONE"
  return 0
}

# Run the sweep.
SUCC=0
FAIL=0
for model in $MODELS_STR; do
  if run_one "$model"; then
    SUCC=$((SUCC + 1))
  else
    FAIL=$((FAIL + 1))
  fi
  echo
done

# Aggregate: combine all per-model summary JSONs into one results file.
echo "[study] aggregating..."
python3 - <<PY
import glob, json, os, sys
from pathlib import Path

results = {
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "fixture": "$FIXTURE",
    "limit": $LIMIT,
    "models": [],
}
for s in sorted(glob.glob("$ROOT/logs/ab/study-*.summary.json")):
    try:
        d = json.loads(Path(s).read_text())
        results["models"].append({
            "tag": d.get("tag", os.path.basename(s)),
            "trial_count": d.get("trial_count"),
            "by_mode": d.get("by_mode"),
            "delta": d.get("delta"),
            "judge_model": d.get("judge_model"),
        })
    except Exception as e:
        print(f"  skip {s}: {e}", file=sys.stderr)

Path("$RESULTS_JSON").write_text(json.dumps(results, indent=2))
print(f"  wrote {len(results['models'])} per-model rows → $RESULTS_JSON")
PY

echo
echo "[study] $(date -u +%H:%M:%S) done. succ=$SUCC fail=$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
