#!/usr/bin/env bash
# Small recall scenario + timing for chump_memory_graph (Personalized PageRank path).
# Uses a fresh SQLite file so the shared pool sees an isolated DB in this process.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DB="${TMPDIR:-/tmp}/chump-mg-bench-$$.db"
export CHUMP_MEMORY_DB_PATH="$DB"
cleanup() { rm -f "$DB"; }
trap cleanup EXIT

cargo test 'memory_graph::tests::associative_recall_benchmark' -- --exact --ignored --nocapture
