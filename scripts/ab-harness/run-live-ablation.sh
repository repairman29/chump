#!/usr/bin/env bash
# run-live-ablation.sh — sanctioned wrapper for the EVAL-063/EVAL-064 re-score
# sweeps. Closes the live-API prerequisite trap documented in:
#
#   - docs/audits/RED_LETTER.md Issue #3 (2026-04-20)
#   - docs/eval/EVAL-060-methodology-fix.md (PR #279 A/A FAIL finding)
#   - PR #282 acceptance-criteria gate on EVAL-063/064
#
# Purpose
# -------
# PR #279 measured 27/30 empty-output trials in Cell A and 29/30 in Cell B
# when run-binary-ablation.py was invoked without a live provider configured.
# The binary exits 1 with no output when OPENAI_API_BASE / OPENAI_API_KEY /
# OPENAI_MODEL are not resolved to a live endpoint. Without them, the
# LLM-judge scorer has nothing to score and A/A calibration FAILs.
#
# This wrapper fixes that by:
#   1. Sourcing .env so TOGETHER_API_KEY resolves
#   2. Exporting the three OPENAI_* env vars pointed at Together free-tier
#      Qwen3-Coder-480B-A35B-Instruct-FP8 (cheapest viable endpoint;
#      ~$0.005/trial; ~$0.30 per 60-trial faculty sweep)
#   3. Running a 3-trial smoke sweep first; aborts if any trial has
#      exit_code != 0 or output_chars <= 50 (EVAL-063/064 acceptance gate)
#   4. Only then running the full n=50 sweep
#
# Spend gate (Together): requires CHUMP_TOGETHER_CLOUD=1, CHUMP_TOGETHER_JOB_REF,
# and TOGETHER_API_KEY — see docs/operations/TOGETHER_SPEND.md
#
# Why Together + Qwen3-Coder-480B (not Anthropic)
# ----------------------------------------------
# The ablation measures what the *chump binary* does when bypass flags are
# set or cleared — the provider behind the binary is a variable we want
# CHEAP + STABLE, not to match EVAL-026's original conditions. Across-
# architecture validation was EVAL-026's job; re-scoring Metacognition /
# Memory / Executive Function under EVAL-060's fixed instrument is a
# different question. Cost-per-sweep dominates when you need n>=50 and
# multiple faculties. Together's Qwen3-Coder serverless was the backend
# that shipped PR #224 end-to-end for COG-031 V9, so we know it's stable
# with the binary. Swap via --provider anthropic if you have specific
# architecture-comparison needs.
#
# Usage
# -----
#   scripts/ab-harness/run-live-ablation.sh <MODULE> [--provider PROVIDER]
#                                                    [--n N] [--faculty FAC]
#
#   MODULE:     belief_state | surprisal | neuromod | spawn_lessons | blackboard | perception
#   PROVIDER:   together (default) | anthropic
#   N:          trials per cell for the full sweep (default: 50)
#   FAC:        "metacog" | "memory" | "execfn"  (sets output file prefix only)
#
# Exit codes
# ----------
#   0   smoke + full sweep both completed
#   1   smoke test failed (no live API, endpoint down, or binary crash)
#   2   usage error or env unavailable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# --- argument parsing ----------------------------------------------------

MODULE="${1:-}"
PROVIDER="together"
N_PER_CELL=50
FACULTY_LABEL=""

shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider) PROVIDER="$2"; shift 2 ;;
        --n)        N_PER_CELL="$2"; shift 2 ;;
        --faculty)  FACULTY_LABEL="$2"; shift 2 ;;
        *) echo "[run-live-ablation] unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <MODULE> [--provider PROVIDER] [--n N] [--faculty FAC]" >&2
    echo "  MODULE:   belief_state | surprisal | neuromod | spawn_lessons | blackboard | perception" >&2
    echo "  PROVIDER: together (default) | anthropic" >&2
    exit 2
fi

# --- env sourcing --------------------------------------------------------

if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
fi

# --- provider wiring -----------------------------------------------------

case "${PROVIDER}" in
    together)
        if [[ -z "${TOGETHER_API_KEY:-}" ]]; then
            echo "[run-live-ablation] ERROR: TOGETHER_API_KEY not set. Add to .env or export directly." >&2
            exit 2
        fi
        if [[ "${CHUMP_TOGETHER_CLOUD:-}" != "1" ]]; then
            echo "[run-live-ablation] ERROR: Together provider requires CHUMP_TOGETHER_CLOUD=1 (opt-in)." >&2
            echo "See docs/operations/TOGETHER_SPEND.md" >&2
            exit 2
        fi
        if [[ -z "${CHUMP_TOGETHER_JOB_REF:-}" ]]; then
            echo "[run-live-ablation] ERROR: CHUMP_TOGETHER_JOB_REF must name an approved budget ticket." >&2
            exit 2
        fi
        export OPENAI_API_BASE="https://api.together.xyz/v1"
        export OPENAI_API_KEY="${TOGETHER_API_KEY}"
        export OPENAI_MODEL="Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8"
        PROVIDER_LABEL="together-qwen3-coder-480b"
        ;;
    anthropic)
        if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
            echo "[run-live-ablation] ERROR: ANTHROPIC_API_KEY not set. Add to .env or export directly." >&2
            exit 2
        fi
        # The chump binary uses native Anthropic when ANTHROPIC_API_KEY is set
        # and OPENAI_API_BASE is unset — don't export OPENAI_* for this path.
        unset OPENAI_API_BASE OPENAI_API_KEY OPENAI_MODEL || true
        PROVIDER_LABEL="anthropic-sonnet-4-5"
        ;;
    *)
        echo "[run-live-ablation] ERROR: unknown provider '${PROVIDER}'. Use together or anthropic." >&2
        exit 2
        ;;
esac

# --- binary check --------------------------------------------------------

BIN="${REPO_ROOT}/target/release/chump"
if [[ ! -x "${BIN}" ]]; then
    echo "[run-live-ablation] Building release binary (not found at ${BIN})..." >&2
    cargo build --release --bin chump 1>&2
fi

# --- smoke sweep (n=3, abort on failure) ---------------------------------

echo "[run-live-ablation] === PHASE 1: SMOKE TEST ==="
echo "[run-live-ablation] module:   ${MODULE}"
echo "[run-live-ablation] provider: ${PROVIDER_LABEL}"
echo "[run-live-ablation] faculty:  ${FACULTY_LABEL:-<unspecified>}"
echo "[run-live-ablation] n/cell:   3 (smoke)"
echo ""

SMOKE_OUT_DIR="${REPO_ROOT}/logs/ab/smoke-$(date +%s)"
mkdir -p "${SMOKE_OUT_DIR}"

python3.12 scripts/ab-harness/run-binary-ablation.py \
    --module "${MODULE}" \
    --n-per-cell 3 \
    --use-llm-judge \
    --binary "${BIN}" \
    --timeout 90 \
    --output-dir "${SMOKE_OUT_DIR}"

# Find the just-written JSONL
SMOKE_JSONL="$(ls -1t "${SMOKE_OUT_DIR}"/*.jsonl 2>/dev/null | head -1)"
if [[ -z "${SMOKE_JSONL}" ]]; then
    echo "[run-live-ablation] ERROR: smoke sweep did not produce a JSONL file" >&2
    exit 1
fi

# Gate: any exit_code != 0 or output_chars <= 50 → abort full sweep
python3.12 - <<PYEOF "${SMOKE_JSONL}"
import json, sys
path = sys.argv[1]
rows = [json.loads(l) for l in open(path) if l.strip()]
n = len(rows)
bad = []
for r in rows:
    ec = r.get("exit_code")
    oc = r.get("output_chars") or 0
    if ec != 0 or oc <= 50:
        bad.append((r.get("task_id"), r.get("cell"), ec, oc))
if bad:
    print(f"[run-live-ablation] SMOKE FAIL — {len(bad)}/{n} trials failed the gate", file=sys.stderr)
    for tid, cell, ec, oc in bad:
        print(f"  {tid} cell={cell} exit_code={ec} output_chars={oc}", file=sys.stderr)
    print("", file=sys.stderr)
    print("[run-live-ablation] Provider endpoint likely not responding to the binary's", file=sys.stderr)
    print("[run-live-ablation] requests. Fix the endpoint before running the full sweep.", file=sys.stderr)
    print("[run-live-ablation] If TOGETHER_API_KEY is set, try a direct curl to confirm:", file=sys.stderr)
    print('[run-live-ablation]   curl -s https://api.together.xyz/v1/models -H "Authorization: Bearer $TOGETHER_API_KEY" | head -c 200', file=sys.stderr)
    sys.exit(1)
print(f"[run-live-ablation] SMOKE PASS — {n}/{n} trials produced output + exited 0")
PYEOF

# --- full sweep ----------------------------------------------------------

echo ""
echo "[run-live-ablation] === PHASE 2: FULL SWEEP (n=${N_PER_CELL}) ==="
echo "[run-live-ablation] Estimated cost: ~\$$(python3.12 -c "print(f'{${N_PER_CELL} * 2 * 0.005:.2f}')") (binary) + ~\$$(python3.12 -c "print(f'{${N_PER_CELL} * 2 * 0.0008:.2f}')") (LLM judge) = ~\$$(python3.12 -c "print(f'{${N_PER_CELL} * 2 * 0.0058:.2f}')") via Together"
echo ""

FULL_OUT_DIR="${REPO_ROOT}/logs/ab"
mkdir -p "${FULL_OUT_DIR}"

python3.12 scripts/ab-harness/run-binary-ablation.py \
    --module "${MODULE}" \
    --n-per-cell "${N_PER_CELL}" \
    --use-llm-judge \
    --binary "${BIN}" \
    --timeout 300 \
    --output-dir "${FULL_OUT_DIR}"
    # --timeout 300: INFRA-016 / INFRA-006. Shorter values (e.g. 60/120s)
    # can mid-inference-disconnect from a local vllm-mlx server, triggering
    # a Metal GPU assertion crash that kills the whole server process
    # ("A command encoder is already encoding to this command buffer").
    # Empirical floor is ~56s (9B-4bit, 20K-char system prompt, 3.7 tok/s);
    # 300s gives 5× headroom. Raise further if the model loads slowly.

echo ""
echo "[run-live-ablation] === COMPLETE ==="
echo "[run-live-ablation] Smoke JSONL: ${SMOKE_JSONL}"
echo "[run-live-ablation] Full JSONL:  ${FULL_OUT_DIR}/eval049-binary-*.jsonl (most recent)"
echo ""
echo "[run-live-ablation] Next: update docs/eval/EVAL-053|056|058-<faculty>-ablation.md"
echo "[run-live-ablation]       + CHUMP_FACULTY_MAP.md per EVAL-063/EVAL-064 acceptance criteria"
