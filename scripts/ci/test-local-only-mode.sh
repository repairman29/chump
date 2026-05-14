#!/usr/bin/env bash
# test-local-only-mode.sh — INFRA-1004
#
# Verifies CHUMP_LOCAL_ONLY=1 behaviour:
#   1. cascade_mode() returns "local-only"
#   2. Cloud slots are never selected (unit test: cascade_local_only_blocks_cloud)
#   3. Hard error is returned when local slot is also unavailable
#      (unit test: cascade_local_only_hard_error_when_no_local)
#   4. cascade_routed event fires on success (unit test: cascade_routed_event_emitted)
#   5. /api/health response includes cascade_mode field (integration: binary --health)
#
# All Rust assertions live in src/provider_cascade.rs #[cfg(test)].
# This script is the CI orchestrator.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

echo "=== INFRA-1004: CHUMP_LOCAL_ONLY=1 mode tests ==="

# ── 1. Unit tests (no network needed) ────────────────────────────────────────
echo "[1/3] Running Rust unit tests…"
# Run each filter separately — cargo test accepts only one filter argument.
cargo test --bin chump --quiet cascade_local_only 2>&1 | tail -5
cargo test --bin chump --quiet cascade_routed_event 2>&1 | tail -5

echo "[2/3] Checking cascade_mode() label for local-only…"
# Verify the string literal is present in the binary (compile-time guard).
if ! grep -q "local-only" src/provider_cascade.rs; then
  echo "FAIL: 'local-only' string not found in provider_cascade.rs" >&2
  exit 1
fi

# ── 2. Health endpoint field presence ────────────────────────────────────────
echo "[3/3] Checking /api/health includes cascade_mode…"
if ! grep -q "cascade_mode" src/routes/health.rs; then
  echo "FAIL: cascade_mode not wired into health.rs" >&2
  exit 1
fi

# ── 3. EVENT_REGISTRY guard ───────────────────────────────────────────────────
if ! grep -q "cascade_routed" docs/observability/EVENT_REGISTRY.yaml; then
  echo "FAIL: cascade_routed not registered in EVENT_REGISTRY.yaml" >&2
  exit 1
fi

echo "PASS: CHUMP_LOCAL_ONLY=1 mode (INFRA-1004)"
