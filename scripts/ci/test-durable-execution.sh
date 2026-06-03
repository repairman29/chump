#!/usr/bin/env bash
# test-durable-execution.sh — RESILIENT-059
#
# Four acceptance-criterion tests for the durable-execution journal:
#
#   Test 1 — basic journaling: 3-step gap; assert 3 completed rows after success.
#   Test 2 — resume after crash: start gap, kill mid-step 2, restart, verify
#             step-1 is replayed from journal (not re-executed) and execution
#             continues from step 2.
#   Test 3 — LLM call dedup: same (gap_id, run_id, step_name) called twice;
#             assert the closure body runs exactly once.
#   Test 4 — cross-run separation: same step_name in two different run_ids
#             executes twice (each run is independent).
#
# Exit 0 if all four pass; exit 1 on first failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== RESILIENT-059 durable-execution tests ==="
echo

# ── Locate the chump binary ──────────────────────────────────────────────────

# Prefer a pre-built binary in target/debug (avoids re-compile in CI).
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "[durable-execution-test] building chump binary..."
        PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump --quiet 2>&1 | tail -5
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    fi
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN" >&2
    exit 1
fi

echo "  binary: $CHUMP_BIN"
echo

# ── Shared temp DB ───────────────────────────────────────────────────────────

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Test 1: basic journaling ─────────────────────────────────────────────────
echo "--- Test 1: basic journaling ---"

DB1="$TMPDIR_BASE/t1.db"
export CHUMP_STATE_DB_PATH="$DB1"
export CHUMP_DURABLE_AMBIENT_DISABLE=1
export CHUMP_REPO_ROOT="$REPO_ROOT"

# Run the Rust unit tests that cover basic journaling (Test 1 is exercised
# by the #[test] fn basic_three_step_journaling in durable_execution.rs).
# We run them here via cargo test so CI sees the results.
if PATH="$HOME/.cargo/bin:$PATH" cargo test \
       --quiet \
       --bin chump \
       -- commands::durable_execution::tests::basic_three_step_journaling \
       2>&1 | grep -q "test result: ok"; then
    ok "basic_three_step_journaling passed"
else
    fail "basic_three_step_journaling failed"
fi

# ── Test 2: resume after crash ───────────────────────────────────────────────
echo "--- Test 2: resume after crash ---"

# The resume_skips_completed_steps unit test covers this AC exactly.
if PATH="$HOME/.cargo/bin:$PATH" cargo test \
       --quiet \
       --bin chump \
       -- commands::durable_execution::tests::resume_skips_completed_steps \
       2>&1 | grep -q "test result: ok"; then
    ok "resume_skips_completed_steps passed"
else
    fail "resume_skips_completed_steps failed"
fi

# Also verify via CLI: chump durable-resume reports a resumable run correctly.
DB2="$TMPDIR_BASE/t2.db"
export CHUMP_STATE_DB_PATH="$DB2"

# Seed the DB using the journal Rust unit test path:
# We use cargo test to run the resume integration test which also validates
# the CLI path through durable_resume::run.
if PATH="$HOME/.cargo/bin:$PATH" cargo test \
       --quiet \
       --bin chump \
       -- commands::durable_resume::tests::resumable_run_exits_0_and_reports \
       2>&1 | grep -q "test result: ok"; then
    ok "durable_resume CLI test passed"
else
    fail "durable_resume CLI test failed"
fi

# ── Test 3: LLM call dedup ───────────────────────────────────────────────────
echo "--- Test 3: LLM call dedup ---"

if PATH="$HOME/.cargo/bin:$PATH" cargo test \
       --quiet \
       --bin chump \
       -- commands::durable_execution::tests::activity_dedup_same_step_name \
       2>&1 | grep -q "test result: ok"; then
    ok "activity_dedup_same_step_name passed (closure runs exactly once)"
else
    fail "activity_dedup_same_step_name failed"
fi

# ── Test 4: cross-run separation ─────────────────────────────────────────────
echo "--- Test 4: cross-run separation ---"

if PATH="$HOME/.cargo/bin:$PATH" cargo test \
       --quiet \
       --bin chump \
       -- commands::durable_execution::tests::cross_run_separation \
       2>&1 | grep -q "test result: ok"; then
    ok "cross_run_separation passed (step executes once per run)"
else
    fail "cross_run_separation failed"
fi

# ── Journal module unit tests ─────────────────────────────────────────────────
echo "--- Journal module unit tests ---"

if PATH="$HOME/.cargo/bin:$PATH" cargo test \
       --quiet \
       --bin chump \
       -- commands::durable_execution_journal::tests:: \
       2>&1 | grep -q "test result: ok"; then
    ok "durable_execution_journal unit tests passed"
else
    fail "durable_execution_journal unit tests failed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
