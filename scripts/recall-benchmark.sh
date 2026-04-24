#!/usr/bin/env bash
# EVAL-003 / COG-002 — Retrieval pipeline recall@5 benchmark.
#
# Creates a fresh temp DB, runs the synthetic multi-hop QA benchmark,
# and appends the markdown table to docs/archive/2026-04/briefs/CONSCIOUSNESS_AB_RESULTS.md.
#
# Usage: bash scripts/recall-benchmark.sh [--dry-run]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_FILE="$(mktemp "/tmp/chump_recall_bench_XXXXXX.db")"
OUT_FILE="${REPO_ROOT}/docs/archive/2026-04/briefs/CONSCIOUSNESS_AB_RESULTS.md"
DRY_RUN="${1:-}"

cleanup() { rm -f "${DB_FILE}"; }
trap cleanup EXIT

echo "recall-benchmark: using temp DB at ${DB_FILE}"

# Run the ignored test; capture stdout (println!) and stderr (eprintln!) separately
OUTPUT="$(
  cd "${REPO_ROOT}"
  CHUMP_MEMORY_DB_PATH="${DB_FILE}" \
    cargo test recall_benchmark_eval_003 -- --ignored --nocapture 2>/dev/null
)"

if [[ -z "${OUTPUT}" ]]; then
  echo "ERROR: benchmark produced no output" >&2
  exit 1
fi

echo "${OUTPUT}"

if [[ "${DRY_RUN}" == "--dry-run" ]]; then
  echo "(dry-run: not appending to ${OUT_FILE})"
  exit 0
fi

# Append retrieval section to the results doc (idempotent via header check)
HEADER="## Retrieval Pipeline Benchmark (EVAL-003 / COG-002)"
if grep -qF "${HEADER}" "${OUT_FILE}" 2>/dev/null; then
  echo "Retrieval section already in ${OUT_FILE} — skipping append."
else
  printf '\n\n---\n\n' >> "${OUT_FILE}"
  echo "${OUTPUT}" | grep -A 9999 "## Retrieval Pipeline Benchmark" >> "${OUT_FILE}"
  echo "Appended benchmark results to ${OUT_FILE}"
fi
