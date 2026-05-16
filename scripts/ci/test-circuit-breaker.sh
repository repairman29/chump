#!/usr/bin/env bash
# RESILIENT-011: circuit-breaker integration tests
#
# Verifies:
#   - Closed state passes through calls
#   - Open state fails fast after error threshold
#   - Half-Open probes and transitions on success
#   - Timeout triggers Open → Half-Open transition
#
# Contract: exits 0 on success, non-zero on failure.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

cd "$repo_root"

# Build tests if not already compiled.
if ! cargo test --test "*" --no-run 2>&1 | grep -q "circuit_breaker"; then
    echo "[test-circuit-breaker] building circuit breaker unit tests..."
    cargo test --lib circuit_breaker:: --no-run || {
        echo "[test-circuit-breaker] FAIL: cargo test build failed"
        exit 1
    }
fi

echo "[test-circuit-breaker] running circuit breaker unit tests..."
cargo test --lib circuit_breaker:: -- --test-threads=1 --nocapture || {
    echo "[test-circuit-breaker] FAIL: unit tests failed"
    exit 1
}

echo "[test-circuit-breaker] OK: all circuit breaker tests passed"
exit 0
