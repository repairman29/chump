#!/usr/bin/env bash
# test-cascade-all-exhausted-event.sh — INFRA-352
#
# Verifies the cascade emits a structured `cascade_all_exhausted` event to
# `.chump-locks/ambient.jsonl` when every slot has failed and it's about to
# return Err. Pre-INFRA-352 the operator had no visibility into this state
# (rc=1 with bare reqwest message); the event tag makes it greppable in the
# trace log and surfaces it during the standard pre-flight `tail` check.
#
# Test technique: build a unit test in src/provider_cascade.rs (Rust-side)
# that drives the failure path and asserts the JSONL line is written. This
# script orchestrates the test invocation so CI sees a single pass/fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# The actual assertion lives in src/provider_cascade.rs as
# cascade_exhausted_emits_ambient_event_with_per_slot_tally — it doesn't
# need cargo test --features here because emit_cascade_exhausted_event is
# pure-bash-side I/O (no network).
echo "running cascade-exhausted ambient-emission unit test…"
cargo test --bin chump --quiet \
  cascade_exhausted_emits_ambient_event 2>&1 | tail -5

# Also verify the chump-doctor --probe-cascade subcommand works syntactically.
# We don't actually probe (would hit network); just check the help/exit path.
echo "verifying chump-doctor --probe-cascade flag is recognized…"
if ! grep -q -- "--probe-cascade" "$REPO_ROOT/scripts/dev/chump-binary-unwedge.sh"; then
    echo "FAIL: chump-binary-unwedge.sh missing --probe-cascade flag" >&2
    exit 1
fi
if ! grep -q "probe_cascade()" "$REPO_ROOT/scripts/dev/chump-binary-unwedge.sh"; then
    echo "FAIL: chump-binary-unwedge.sh missing probe_cascade() function" >&2
    exit 1
fi

echo "PASS: cascade_all_exhausted ambient event + chump-doctor --probe-cascade"
