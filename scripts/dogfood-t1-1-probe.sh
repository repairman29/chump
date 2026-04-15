#!/usr/bin/env bash
# Fixed acceptance probe for DOGFOOD_TASKS **T1.1** — swap `OPENAI_MODEL` (and optional
# `OPENAI_API_BASE`) and re-run until verify passes. Does **not** mark the task “done” in git;
# it only reports pass/fail for each model attempt.
#
# Usage:
#   OPENAI_MODEL=qwen2.5:14b ./scripts/dogfood-t1-1-probe.sh
#   OPENAI_MODEL=qwen3:8b OPENAI_API_BASE=http://127.0.0.1:11434/v1 ./scripts/dogfood-t1-1-probe.sh
#
# Logs:
#   - Same as dogfood-run: logs/dogfood/<timestamp>.log
#   - Append-only metrics: logs/dogfood/t1.1-model-probes.jsonl (under logs/, gitignored)
#
# Verify (T1.1 production goal):
#   - No `SESSION_OVERRIDES.lock().expect` in src/policy_override.rs
#   - `cargo test --bin chump` passes
set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

if [[ -z "${OPENAI_MODEL:-}" ]]; then
  echo "error: set OPENAI_MODEL to the model tag you are probing (e.g. qwen2.5:14b)." >&2
  echo "  Example: OPENAI_MODEL=qwen3:8b $0" >&2
  exit 2
fi

mkdir -p "$ROOT/logs/dogfood"
JSONL="$ROOT/logs/dogfood/t1.1-model-probes.jsonl"

if ! "$ROOT/scripts/check-heartbeat-preflight.sh" &>/dev/null; then
  echo "error: model server preflight failed. Start Ollama, or for vLLM on 8000 run ./scripts/restart-vllm-if-down.sh then ./scripts/wait-for-vllm.sh (poll only; avoids overlapping starts during HF download)." >&2
  exit 1
fi

# Exact prompt from docs/DOGFOOD_TASKS.md (T1.1) — keep in sync if the task text changes.
PROMPT='In `src/policy_override.rs`, in `map_lock()`, replace `SESSION_OVERRIDES.lock().expect("policy override map lock")` with `SESSION_OVERRIDES.lock().unwrap_or_else(|e| e.into_inner())` so the mutex is acquired without `.expect` (standard poison recovery). Run `cargo test --bin chump` after.'

echo "=== T1.1 model probe ===" >&2
echo "OPENAI_MODEL=$OPENAI_MODEL" >&2
echo "OPENAI_API_BASE=${OPENAI_API_BASE:-<from .env>}" >&2
echo "" >&2

"$ROOT/scripts/dogfood-run.sh" "$PROMPT"
DOG_EXIT=$?

mutex_ok=1
if grep -q 'SESSION_OVERRIDES\.lock()\.expect' "$ROOT/src/policy_override.rs" 2>/dev/null; then
  mutex_ok=0
fi

tests_ok=0
if cargo test --bin chump -q 2>/dev/null; then
  tests_ok=1
fi

probe_ok=0
if [[ "$mutex_ok" -eq 1 && "$tests_ok" -eq 1 ]]; then
  probe_ok=1
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
base="${OPENAI_API_BASE:-}"
# One-line JSON for jq-friendly analysis (append to jsonl)
printf '%s\n' "{\"ts\":\"$ts\",\"task\":\"T1.1\",\"model\":\"${OPENAI_MODEL//\"/\\\"}\",\"openai_api_base\":\"${base//\"/\\\"}\",\"dogfood_exit\":$DOG_EXIT,\"mutex_expect_removed\":$mutex_ok,\"cargo_test_ok\":$tests_ok,\"t1_1_probe_ok\":$probe_ok}" >>"$JSONL"

echo "" >&2
echo "=== T1.1 verify ===" >&2
echo "  mutex .expect removed (prod): $([[ $mutex_ok -eq 1 ]] && echo yes || echo no)" >&2
echo "  cargo test --bin chump:          $([[ $tests_ok -eq 1 ]] && echo pass || echo fail)" >&2
echo "  dogfood-run exit:                $DOG_EXIT" >&2
echo "  metrics:                         $JSONL" >&2
if [[ "$probe_ok" -eq 1 ]]; then
  echo "" >&2
  echo "T1.1 probe **PASS** — add a Run entry to docs/DOGFOOD_LOG.md, then you may advance the queue." >&2
  exit 0
fi
echo "" >&2
echo "T1.1 probe **FAIL** — task stays open; try another model or fix infra, then append docs/DOGFOOD_LOG.md." >&2
exit 1
