#!/usr/bin/env bash
# run-queue.sh — fire a queue of A/B experiments serially.
#
# Pattern: ollama can only run one model effectively at a time, so any
# attempt to fire multiple A/Bs in parallel just queues them inside
# ollama and burns wall clock. This script runs them one after another,
# scoring + appending each result before launching the next.
#
# Usage:
#   scripts/ab-harness/run-queue.sh                # default queue
#   scripts/ab-harness/run-queue.sh --dry-run      # preview
#   scripts/ab-harness/run-queue.sh --skip <tag>   # skip a queued item
#
# Default queue is hardcoded — edit the QUEUE array to add/remove. Each
# entry is a 5-tuple: TAG | FIXTURE | FLAG | GAP_ID | NOTE.
#
# Pre-launch checks:
#   - Skip if a previous run with the same TAG already produced a
#     summary JSON (idempotent, no double-runs).
#   - Skip if Ollama unreachable.
#   - Skip if release binary missing.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DRY_RUN=0
SKIPS=("__sentinel__")
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip) SKIPS+=("__pending_skip__") ;;  # placeholder; consumed by next iter
    --help|-h) sed -n '2,25p' "$0"; exit 0 ;;
    *)
      # Consume into SKIPS if last was --skip
      if [[ ${#SKIPS[@]} -gt 0 && "${SKIPS[-1]}" == "__pending_skip__" ]]; then
        SKIPS[-1]="$arg"
      fi
      ;;
  esac
done

CHUMP_BIN="${CHUMP_BIN:-./target/release/chump}"
OLLAMA_BASE="${OLLAMA_BASE:-http://127.0.0.1:11434}"

# Default queue. Edit to add new experiments. Format:
#   TAG|FIXTURE|FLAG|GAP_ID|NOTE
QUEUE=(
  "perception-ab-qwen25-7b|scripts/ab-harness/fixtures/perception_tasks.json|CHUMP_PERCEPTION_ENABLED|COG-005|qwen2.5:7b, structured/trivial split"
  "neuromod-ab-qwen25-7b|scripts/ab-harness/fixtures/neuromod_tasks.json|CHUMP_NEUROMOD_ENABLED|COG-006|qwen2.5:7b, dynamic/trivial split"
  "reflection-ab-qwen25-14b|scripts/ab-harness/fixtures/reflection_tasks.json|CHUMP_REFLECTION_INJECTION|COG-011d-d|larger model variant of the COG-011 fixture"
)

echo "[queue] $(date -u +%H:%M:%S) start: $((${#QUEUE[@]})) experiment(s)"
echo "[queue] chump=$CHUMP_BIN  ollama=$OLLAMA_BASE  dry-run=$DRY_RUN"
echo

# Pre-flight.
if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "ERROR: $CHUMP_BIN not executable (cargo build --release --bin chump)" >&2
  exit 2
fi
if ! curl -sf --connect-timeout 3 "$OLLAMA_BASE/api/tags" >/dev/null 2>&1; then
  echo "ERROR: ollama not reachable at $OLLAMA_BASE" >&2
  exit 3
fi

run_one() {
  local tag="$1" fixture="$2" flag="$3" gap_id="$4" note="$5"

  # Idempotency: if a summary file already exists for this tag, skip.
  local existing
  existing=$(ls "$ROOT/logs/ab/${tag}-"*.summary.json 2>/dev/null | head -1)
  if [[ -n "$existing" ]]; then
    echo "[queue] [$tag] SKIP — summary exists: $(basename "$existing")"
    return 0
  fi

  # Honor --skip.
  for s in "${SKIPS[@]}"; do
    [[ "$s" == "$tag" ]] && {
      echo "[queue] [$tag] SKIP — --skip"
      return 0
    }
  done

  echo "[queue] [$tag] $(date -u +%H:%M:%S) START gap=$gap_id"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  would run: scripts/ab-harness/run.sh --fixture $fixture --flag $flag --tag $tag --limit 20"
    echo "  would score: scripts/ab-harness/score.py <jsonl> $fixture --judge qwen2.5:7b"
    echo "  would append: scripts/ab-harness/append-result.sh <summary> $gap_id --note ..."
    return 0
  fi

  # Pick model for the run. Default qwen2.5:7b; specific tags override.
  local run_model="qwen2.5:7b"
  case "$tag" in
    *14b*) run_model="qwen2.5:14b" ;;
  esac

  # Wait for ollama to be reachable + idle (no other heavy load).
  # Simple check: just /api/tags responds in <2s.
  local waits=0
  while ! curl -sf --connect-timeout 2 --max-time 2 "$OLLAMA_BASE/api/tags" >/dev/null 2>&1; do
    waits=$((waits + 1))
    if [[ $waits -gt 60 ]]; then
      echo "[queue] [$tag] FAIL — ollama unreachable after 5min wait" >&2
      return 1
    fi
    sleep 5
  done

  # Run the harness.
  OPENAI_API_BASE="${OLLAMA_BASE}/v1" \
  OPENAI_API_KEY=ollama \
  OPENAI_MODEL="$run_model" \
  CHUMP_OLLAMA_NUM_CTX=8192 \
  CHUMP_HOME="$ROOT" \
  CHUMP_REPO="$ROOT" \
    scripts/ab-harness/run.sh \
      --fixture "$fixture" \
      --flag "$flag" \
      --tag "$tag" \
      --limit 20 \
      --chump-bin "$CHUMP_BIN" || {
    echo "[queue] [$tag] FAIL — harness exited nonzero" >&2
    return 1
  }

  # Find the just-written JSONL (newest matching tag).
  local jsonl
  jsonl=$(ls -t "$ROOT/logs/ab/${tag}-"*.jsonl 2>/dev/null | head -1)
  if [[ -z "$jsonl" ]]; then
    echo "[queue] [$tag] FAIL — no jsonl produced" >&2
    return 1
  fi

  # Score with judge.
  echo "[queue] [$tag] $(date -u +%H:%M:%S) scoring..."
  scripts/ab-harness/score.py "$jsonl" "$fixture" --judge qwen2.5:7b || {
    echo "[queue] [$tag] WARN — scoring failed; trying without judge" >&2
    scripts/ab-harness/score.py "$jsonl" "$fixture" || {
      echo "[queue] [$tag] FAIL — both scoring paths failed" >&2
      return 1
    }
  }

  # Append.
  local summary="${jsonl%.jsonl}.summary.json"
  if [[ -f "$summary" ]]; then
    OPENAI_MODEL="$run_model" \
    OPENAI_API_BASE="${OLLAMA_BASE}/v1" \
      scripts/ab-harness/append-result.sh "$summary" "$gap_id" --note "$note (auto-fired by run-queue.sh)" || true
  fi

  echo "[queue] [$tag] $(date -u +%H:%M:%S) DONE"
  echo
  return 0
}

PASSED=0
FAILED=0
for entry in "${QUEUE[@]}"; do
  IFS='|' read -r tag fixture flag gap_id note <<< "$entry"
  if run_one "$tag" "$fixture" "$flag" "$gap_id" "$note"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done

echo "[queue] $(date -u +%H:%M:%S) all done. passed=$PASSED failed=$FAILED"
[[ $FAILED -eq 0 ]] && exit 0 || exit 1
