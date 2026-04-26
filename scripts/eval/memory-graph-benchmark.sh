#!/usr/bin/env bash
# Phase F3: memory graph benchmark — 50-hop chain timing + curated recall@5 (hub entity).
# Correctness of curated PPR is enforced by default CI: `cargo test memory_graph_curated_recall_topk`.
# Uses a fresh SQLite file so the shared pool sees an isolated DB in this process.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
DB="${TMPDIR:-/tmp}/chump-mg-bench-$$.db"
export CHUMP_MEMORY_DB_PATH="$DB"
cleanup() { rm -f "$DB"; }
trap cleanup EXIT

cargo test 'memory_graph::tests::associative_recall_benchmark' -- --exact --ignored --nocapture
