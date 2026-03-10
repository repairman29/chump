#!/usr/bin/env bash
# Local automation: build, test, and clippy for rust-agent.
# Run from repo root or rust-agent/. Use before pushing or in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "==> cargo build --release"
cargo build --release
echo "==> cargo test"
cargo test
echo "==> cargo clippy --release -- -D warnings"
cargo clippy --release -- -D warnings
echo "==> check passed"
