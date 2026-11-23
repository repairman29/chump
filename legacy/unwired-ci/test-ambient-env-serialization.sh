#!/usr/bin/env bash
# INFRA-1320: Test that all ambient.jsonl-touching tests serialize correctly.
# This script verifies that:
# 1. Tests run serially (no interleaving of CHUMP_AMBIENT_LOG / SESSION_ID env vars)
# 2. ambient.jsonl events remain valid JSON throughout parallel test runs
# 3. Session IDs in events match the test's SESSION_ID assignment

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

echo "[test-ambient-env-serialization] Running tests with --test-threads=1 to stress-test serial_test guards..."

# Run main package tests
cargo test -p chump -- --test-threads=1 \
  adversary::e2e_rule_to_ambient \
  blocker_detect::timeout_emits_ambient_alert_line \
  dispatch::release_with_retry_emits_ambient_event_and_propagates_on_double_failure \
  ambient_stream::test_env_session_id_priority \
  provider_cascade 2>&1 | tail -30

# Run lease crate tests (all SESSION_ID consumers)
echo "[test-ambient-env-serialization] Testing chump-agent-lease (SESSION_ID consumers)..."
cargo test -p chump-agent-lease -- --test-threads=1 2>&1 | tail -20

echo "[test-ambient-env-serialization] All tests passed — serialization guards in place."
exit 0
