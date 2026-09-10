#!/usr/bin/env bash
# test-effective-1567.sh — EFFECTIVE-1567 coverage for src/bin/openrouter_model_index.rs
#
# Runs the unit tests covering the merge_index() upsert logic that backs
# AC #3 (persisted to deterministic local JSON) and AC #4 (re-run without
# duplicating entries).
#
# Run from repo root: bash scripts/ci/test-effective-1567.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PATH="$HOME/.cargo/bin:$PATH" cargo test --bin openrouter-model-index -- --nocapture
