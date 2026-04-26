#!/usr/bin/env bash
# Local automation: build, test, fmt, and clippy for the chump package.
# Run from repo root or Chump/. Use before pushing or in CI.
# Optional: CHECK_FEATURES=inprocess-embed to build with that feature (e.g. for max_m4).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FEATURES="${CHECK_FEATURES:-}"
BUILD_OPTS=(--release)
[[ -n "$FEATURES" ]] && BUILD_OPTS+=(--features "$FEATURES")

echo "==> cargo fmt -- --check"
cargo fmt -- --check
echo "==> cargo build ${BUILD_OPTS[*]}"
cargo build "${BUILD_OPTS[@]}"
echo "==> cargo test"
cargo test
echo "==> cargo clippy ${BUILD_OPTS[*]} -- -D warnings"
cargo clippy "${BUILD_OPTS[@]}" -- -D warnings
echo "==> check passed"
