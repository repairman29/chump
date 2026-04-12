#!/usr/bin/env bash
# Drive scripts/bench_mistralrs_chump.py — in-process mistral.rs timing via release chump.
#
# Prereq: release binary with mistral feature, e.g.
#   cargo build --release --features mistralrs-metal -p rust-agent
#
# Passes through HF_TOKEN, CHUMP_MISTRALRS_HF_REVISION, CHUMP_BENCH_BINARY from the environment.
#
# Example:
#   ./scripts/bench-mistralrs-chump.sh --model Qwen/Qwen3-4B --isq 4,6,8 --runs 2 --warmup --summary \\
#     -o logs/mistralrs-bench-$(date -u +%Y%m%dT%H%M%SZ).csv
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec python3 "$ROOT/scripts/bench_mistralrs_chump.py" "$@"
