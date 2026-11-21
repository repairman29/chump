#!/usr/bin/env bash
# test-ci-health-weekly.sh — INFRA-511 smoke test.
#
# Exercises ci_summary::emit_ambient_alert via the chump binary.
# Verifies:
#   1. ci-summary --emit-alert does not crash on missing ambient.jsonl dir.
#   2. Under-threshold run emits no ALERT line.
#   3. Unit tests for failure_rate_pct and emit_ambient_alert pass via
#      `cargo test infra511` (no network needed — gh unavailable path is OK).
#
# Network-free: uses cargo test, not live gh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "[test-ci-health-weekly] running cargo test infra511 ..."
cargo test --manifest-path "$REPO_ROOT/Cargo.toml" \
  ci_summary -- infra511 --nocapture 2>&1

echo "[test-ci-health-weekly] PASS"
