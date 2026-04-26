#!/usr/bin/env bash
# run-neuromod-study.sh — COG-006 A/B driver.
#
# COG-006 acceptance: "CHUMP_NEUROMOD_ENABLED=0 vs 1 A/B on 50-turn task set;
# task success rate and tool efficiency delta reported. Section 3.3 gate evaluated."
#
# Runs the neuromod_tasks.json fixture (50 tasks) under a single local model
# with CHUMP_NEUROMOD_ENABLED toggled (A=1, B=0). Scores via Claude Sonnet judge
# when ANTHROPIC_API_KEY is set, falls back to local Ollama judge.
# Idempotent — resumes if summary.json already exists.
#
# Usage:
#   scripts/eval/run-neuromod-study.sh                     # full run (default model)
#   scripts/eval/run-neuromod-study.sh --dry-run           # preview
#   scripts/eval/run-neuromod-study.sh --model qwen3:8b    # override model
#   scripts/eval/run-neuromod-study.sh --fixture <path>    # custom fixture
#
# Env:
#   CHUMP_NEUROMOD_MODEL   default "qwen3:8b"
#   CHUMP_STUDY_LIMIT      default 50
#   OLLAMA_BASE            default http://127.0.0.1:11434
#   CHUMP_BIN              default ./target/release/chump

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/.env" ]]; then
  set -a; source "$ROOT/.env"; set +a
fi

FIXTURE="${CHUMP_NEUROMOD_FIXTURE:-scripts/ab-harness/fixtures/neuromod_tasks.json}"
MODEL="${CHUMP_NEUROMOD_MODEL:-qwen3:8b}"
LIMIT="${CHUMP_STUDY_LIMIT:-50}"
OLLAMA_BASE="${OLLAMA_BASE:-http://127.0.0.1:11434}"
CHUMP_BIN="${CHUMP_BIN:-./target/release/chump}"

JUDGE_CLAUDE_MODEL="${CHUMP_JUDGE_CLAUDE:-}"
JUDGE_OLLAMA_MODEL="${CHUMP_JUDGE_OLLAMA:-qwen2.5:14b}"
if [[ -z "$JUDGE_CLAUDE_MODEL" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
  JUDGE_CLAUDE_MODEL="claude-sonnet-4-6"
fi

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --fixture) FIXTURE="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
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
if ! curl -sf --connect-timeout 3 "$OLLAMA_BASE/api/tags" >/dev/null 2>&1; then
  echo "ERROR: ollama not reachable at $OLLAMA_BASE" >&2; exit 3
fi

OUT_DIR="$ROOT/logs/study"
mkdir -p "$OUT_DIR"
TS="$(date +%s)"
RESULTS_JSON="$OUT_DIR/neuromod-${TS}.json"
TAG="neuromod-${MODEL//[:.]/-}"

if [[ -n "$JUDGE_CLAUDE_MODEL" ]]; then
  JUDGE_DESC="claude:$JUDGE_CLAUDE_MODEL (independent)"
else
  JUDGE_DESC="ollama:$JUDGE_OLLAMA_MODEL (local fallback)"
fi

echo "[neuromod] $(date -u +%H:%M:%S) start"
echo "[neuromod] fixture=$FIXTURE  limit=$LIMIT"
echo "[neuromod] model=$MODEL"
echo "[neuromod] judge=$JUDGE_DESC"
echo "[neuromod] results → $RESULTS_JSON"
echo

# Idempotency: skip if summary already exists.
existing=$(ls "$ROOT/logs/ab/${TAG}-"*.summary.json 2>/dev/null | head -1)
if [[ -n "$existing" ]]; then
  echo "[neuromod] SKIP — $existing already exists (idempotent)"
  SUMMARY="$existing"
else
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  would run: scripts/ab-harness/run.sh --fixture $FIXTURE --flag CHUMP_NEUROMOD_ENABLED --tag $TAG --limit $LIMIT --chump-bin $CHUMP_BIN"
    exit 0
  fi

  OPENAI_API_BASE="${OLLAMA_BASE}/v1" \
  OPENAI_API_KEY=ollama \
  OPENAI_MODEL="$MODEL" \
  CHUMP_OLLAMA_NUM_CTX=8192 \
  CHUMP_HOME="$ROOT" \
  CHUMP_REPO="$ROOT" \
    scripts/ab-harness/run.sh \
      --fixture "$FIXTURE" \
      --flag CHUMP_NEUROMOD_ENABLED \
      --tag "$TAG" \
      --limit "$LIMIT" \
      --chump-bin "$CHUMP_BIN" || {
    echo "[neuromod] FAIL — harness exited nonzero" >&2; exit 1
  }

  JSONL=$(ls -t "$ROOT/logs/ab/${TAG}-"*.jsonl 2>/dev/null | head -1)
  [[ -z "$JSONL" ]] && { echo "[neuromod] FAIL — no jsonl output"; exit 1; }

  echo "[neuromod] $(date -u +%H:%M:%S) scoring..."
  if [[ -n "$JUDGE_CLAUDE_MODEL" ]]; then
    scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge-claude "$JUDGE_CLAUDE_MODEL" || {
      echo "[neuromod] WARN — Claude judge failed, trying local fallback" >&2
      scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge "$JUDGE_OLLAMA_MODEL" || {
        echo "[neuromod] WARN — local judge also failed, structural only" >&2
        scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
      }
    }
  else
    scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge "$JUDGE_OLLAMA_MODEL" || {
      echo "[neuromod] WARN — judge failed, structural only" >&2
      scripts/ab-harness/score.py "$JSONL" "$FIXTURE" || exit 1
    }
  fi

  SUMMARY=$(ls -t "$ROOT/logs/ab/${TAG}-"*.summary.json 2>/dev/null | head -1)
  [[ -z "$SUMMARY" ]] && { echo "[neuromod] FAIL — no summary.json"; exit 1; }
fi

# Aggregate into results file.
echo "[neuromod] aggregating..."
python3 - <<PY
import json, os
from pathlib import Path

summary = json.loads(Path("$SUMMARY").read_text())
results = {
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "fixture": "$FIXTURE",
    "limit": $LIMIT,
    "model": "$MODEL",
    "tag": summary.get("tag"),
    "trial_count": summary.get("trial_count"),
    "by_mode": summary.get("by_mode"),
    "by_category": summary.get("by_category"),
    "delta": summary.get("delta"),
    "delta_by_category": summary.get("delta_by_category"),
    "tool_efficiency_delta": summary.get("tool_efficiency_delta"),
    "judge_model": summary.get("judge_model"),
    "judge_api": summary.get("judge_api"),
}
Path("$RESULTS_JSON").write_text(json.dumps(results, indent=2))
print(f"  wrote results → $RESULTS_JSON")
a = (results.get("by_mode") or {}).get("A", {})
b = (results.get("by_mode") or {}).get("B", {})
print(f"  neuromod ON  (A): pass={a.get('rate','?')}  avg_tools={a.get('avg_tool_calls','?')}")
print(f"  neuromod OFF (B): pass={b.get('rate','?')}  avg_tools={b.get('avg_tool_calls','?')}")
ted = results.get("tool_efficiency_delta")
print(f"  pass-rate delta (A-B): {results.get('delta',0):+.3f}")
print(f"  tool efficiency delta (A-B): {ted:+.3f}" if ted is not None else "  tool efficiency delta: n/a")
PY

echo
echo "[neuromod] $(date -u +%H:%M:%S) populating paper section 3.3..."
scripts/setup/populate-paper-section33.sh "$RESULTS_JSON" 2>/dev/null || \
  echo "  (populate-paper-section33.sh failed — results JSON ready but paper not updated)"

echo
echo "[neuromod] $(date -u +%H:%M:%S) done."
