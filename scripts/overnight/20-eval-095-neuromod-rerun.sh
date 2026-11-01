#!/usr/bin/env bash
# 20-eval-095-neuromod-rerun.sh — overnight empirical replication of EVAL-069
# (CHUMP_BYPASS_NEUROMOD ablation) on the current chump binary.
#
# Filed by EVAL-090's closeout (2026-05-01) — the methodological audit was
# settled by archived-JSONL inspection; this is the deferred empirical re-run.
# Cheap insurance: n=20/cell, ~50 min wall-clock, ~$0.50 Anthropic spend.
#
# Outcome paths (read by the daytime agent that picks up the result):
# - logs/ab/eval049-binary-llmjudge-*.jsonl  (most recent)
# - .chump/overnight/<run-id>.log  (full stdout, captured by harness)
#
# If this run produces |delta| > 0.10 with CI excluding zero, file a follow-up
# to update FINDINGS.md F3 caveat (the EVAL-069 verdict may not survive the
# current binary's neuromod changes).

set -euo pipefail

GAP="EVAL-095"
TS="$(date -u +%FT%TZ)"
echo "[${TS}] ${GAP}: starting n=20/cell neuromod ablation re-run"

# Pre-flight: required env + binary
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi
fi
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "[${TS}] ${GAP}: ANTHROPIC_API_KEY missing — aborting (skipped, not a failure)"
  exit 0
fi

BIN="${CHUMP_BIN:-./target/release/chump}"
if [[ ! -x "${BIN}" ]]; then
  echo "[${TS}] ${GAP}: chump binary missing at ${BIN} — building"
  cargo build --release --bin chump 2>&1 | tail -3
fi

# Ollama liveness
if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "[${TS}] ${GAP}: Ollama not reachable at 127.0.0.1:11434 — aborting (skipped, not a failure)"
  exit 0
fi

# Smoke (fail fast if scorer is broken — the EVAL-090 lesson)
SMOKE_OUT="/tmp/${GAP}-smoke-${TS//[:-]/}"
mkdir -p "${SMOKE_OUT}"
OPENAI_API_BASE="http://127.0.0.1:11434/v1" \
  python3.12 scripts/ab-harness/run-binary-ablation.py \
    --module neuromod \
    --n-per-cell 1 \
    --binary "${BIN}" \
    --scorer llm-judge \
    --judge-family anthropic \
    --agent-provider ollama \
    --agent-model qwen2.5:14b \
    --output-dir "${SMOKE_OUT}" \
    --timeout 300 2>&1 | tail -10

SMOKE_JSONL="$(ls -t "${SMOKE_OUT}"/eval049-binary-llmjudge-*.jsonl 2>/dev/null | head -1)"
# Guard against BOTH (a) the EVAL-069 broken-scorer foot-gun AND (b) a wholly
# degenerate run where chump returns empty output (observed 2026-05-02:
# ~120s wall-clock per trial means the harness's old 120s timeout fires
# first and produces scorer=llm_judge but output_chars=0). Either failure
# would silently produce a fake delta=0 result.
if [[ -z "${SMOKE_JSONL}" ]] || ! python3.12 -c "
import json, sys
rows = [json.loads(l) for l in open('${SMOKE_JSONL}')]
scorer_ok = all(r.get('scorer') == 'llm_judge' for r in rows)
output_ok = all(r.get('output_chars', 0) > 0 for r in rows)
exit_ok = all(r.get('exit_code', -1) == 0 for r in rows)
if not scorer_ok:
    print('SMOKE FAIL: scorer not llm_judge')
elif not output_ok:
    print('SMOKE FAIL: chump returned empty output (chars=0). Probably a binary-too-slow-for-timeout regression — try bumping --timeout or rebuilding the binary.')
elif not exit_ok:
    print('SMOKE FAIL: chump exit_code != 0 — check binary or env')
sys.exit(0 if (scorer_ok and output_ok and exit_ok) else 1)
"; then
  echo "[${TS}] ${GAP}: smoke FAILED — aborting full sweep (see line above)"
  exit 1
fi

# Full sweep
echo "[${TS}] ${GAP}: smoke OK, starting n=20/cell sweep"
mkdir -p logs/ab
OPENAI_API_BASE="http://127.0.0.1:11434/v1" \
  python3.12 scripts/ab-harness/run-binary-ablation.py \
    --module neuromod \
    --n-per-cell 20 \
    --binary "${BIN}" \
    --scorer llm-judge \
    --judge-family anthropic \
    --agent-provider ollama \
    --agent-model qwen2.5:14b \
    --output-dir logs/ab \
    --timeout 300

JSONL="$(ls -t logs/ab/eval049-binary-llmjudge-*.jsonl 2>/dev/null | head -1)"
echo "[${TS}] ${GAP}: sweep complete — $(wc -l < "${JSONL}") rows in ${JSONL}"

# Quick analysis line so the daytime agent doesn't have to recompute
python3.12 - "${JSONL}" <<'PY'
import json, sys, collections
rows = [json.loads(l) for l in open(sys.argv[1])]
cells = collections.defaultdict(list)
for r in rows:
    if r.get('scorer') == 'llm_judge':
        cells[r['cell']].append(int(bool(r.get('correct'))))
n_a, n_b = len(cells.get('A', [])), len(cells.get('B', []))
acc_a = sum(cells.get('A', [])) / n_a if n_a else float('nan')
acc_b = sum(cells.get('B', [])) / n_b if n_b else float('nan')
print(f"[summary] n_A={n_a} acc_A={acc_a:.3f} | n_B={n_b} acc_B={acc_b:.3f} | delta(A-B)={acc_a-acc_b:+.3f}")
PY
