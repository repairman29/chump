#!/usr/bin/env bash
# Compile-check and run mistral.rs-only unit tests (no model download).
# Use in CI and locally: ./scripts/check-mistralrs-infer-build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
cargo check -p chump --bin chump --features mistralrs-infer
cargo test -p chump --features mistralrs-infer mistralrs_provider
