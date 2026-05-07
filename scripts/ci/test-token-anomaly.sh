#!/usr/bin/env bash
# INFRA-642: CI gate for token-anomaly detection in cost_watch.rs
# Runs cargo test with filters covering normal + outlier fixtures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

echo "=== test-token-anomaly: running unit tests ==="
cargo test \
  --bin chump \
  --quiet \
  -- \
  cost_watch::tests::test_p50_odd \
  cost_watch::tests::test_p50_even \
  cost_watch::tests::test_p50_single \
  cost_watch::tests::test_no_anomaly_within_threshold \
  cost_watch::tests::test_anomaly_triggered_above_threshold \
  cost_watch::tests::test_no_anomaly_empty_baseline \
  cost_watch::tests::test_window_excludes_old_events \
  cost_watch::tests::test_current_session_excluded_from_baseline \
  cost_watch::tests::test_emit_token_anomaly_writes_jsonl \
  2>&1

echo "=== test-token-anomaly: PASS ==="
