#!/usr/bin/env bash
# test-rust-builder-image.sh — INFRA-2287 (Lever 1 last mile) smoke test
#
# Pulls ghcr.io/repairman29/chump-ci:latest and runs the same checks the
# fast-checks/clippy CI jobs run inside it (cargo fmt, cargo clippy, a
# quick cargo test of the chump binary), so a bad image is caught before
# ci.yml's `container:` jobs start failing every PR.
#
# Usage:
#   bash scripts/ci/test-rust-builder-image.sh                 # pull :latest
#   CHUMP_CI_IMAGE=ghcr.io/repairman29/chump-ci:abc123 bash scripts/ci/test-rust-builder-image.sh
#
# Requires: docker. Skips (exit 0) if docker is unavailable — this script is
# meant to run in CI (which always has docker) and optionally by an operator
# locally; it must not block a dev machine that lacks docker.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

IMAGE="${CHUMP_CI_IMAGE:-ghcr.io/repairman29/chump-ci:latest}"

if ! command -v docker >/dev/null 2>&1; then
  echo "test-rust-builder-image: docker not available, skipping (exit 0)"
  exit 0
fi

echo "test-rust-builder-image: pulling ${IMAGE}"
if ! docker pull "${IMAGE}"; then
  echo "::error::test-rust-builder-image: failed to pull ${IMAGE}"
  exit 1
fi

run_in_image() {
  docker run --rm \
    -v "${REPO_ROOT}:/chump" \
    -w /chump \
    -e CARGO_HOME=/usr/local/cargo \
    "${IMAGE}" \
    bash -lc "$1"
}

echo "test-rust-builder-image: cargo fmt --all -- --check"
if ! run_in_image "cargo fmt --all -- --check"; then
  echo "::error::test-rust-builder-image: cargo fmt failed inside ${IMAGE}"
  exit 1
fi

echo "test-rust-builder-image: cargo clippy --workspace -- -D warnings"
if ! run_in_image "cargo clippy --workspace -- -D warnings"; then
  echo "::error::test-rust-builder-image: cargo clippy failed inside ${IMAGE}"
  exit 1
fi

echo "test-rust-builder-image: cargo test --bin chump --quiet"
if ! run_in_image "cargo test --bin chump --quiet"; then
  echo "::error::test-rust-builder-image: cargo test --bin chump failed inside ${IMAGE}"
  exit 1
fi

echo "test-rust-builder-image: PASS — ${IMAGE} builds+lints+tests chump cleanly"
exit 0
