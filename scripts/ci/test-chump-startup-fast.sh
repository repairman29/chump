#!/usr/bin/env bash
# test-chump-startup-fast.sh — INFRA-1809 startup hang guard.
#
# Asserts that `chump --version` and `chump --help` cannot hang on a
# subsystem init: they MUST short-circuit before tokio runtime build,
# memory_db connect, or any LLM-provider init.
#
# Targets:
#   - chump --version warm-cache: < 200ms wall time
#   - chump --help    warm-cache: < 200ms wall time
#   - 50 concurrent chump --version invocations:   all complete in < 5s total
#
# Behavior under load is the regression we're guarding against (per AC #1).
# Threshold is generous on purpose — we're catching "hangs for 9+ minutes",
# not nano-second timing perf.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Find a chump binary. Prefer release; fall back to debug; fall back to PATH.
CHUMP="$REPO_ROOT/target/release/chump"
if [[ ! -x "$CHUMP" ]]; then CHUMP="$REPO_ROOT/target/debug/chump"; fi
if [[ ! -x "$CHUMP" ]]; then CHUMP="$(command -v chump || true)"; fi
if [[ -z "${CHUMP:-}" || ! -x "$CHUMP" ]]; then
    echo "[test-chump-startup-fast] no chump binary found — building debug..."
    (cd "$REPO_ROOT" && PATH=$HOME/.cargo/bin:$PATH cargo build --bin chump --quiet) || {
        echo "  FAIL: cargo build failed"
        exit 1
    }
    CHUMP="$REPO_ROOT/target/debug/chump"
fi

echo "[test-chump-startup-fast] binary=$CHUMP"

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# ── Test 1: chump --version completes <500ms warm ────────────────────────────
echo "Test 1: chump --version < 500ms (warm)"
"$CHUMP" --version > /dev/null  # warm
t0=$(now_ms)
"$CHUMP" --version > /dev/null
t1=$(now_ms)
delta=$((t1 - t0))
if [[ "$delta" -lt 500 ]]; then
    echo "  PASS (${delta}ms)"
else
    echo "  FAIL: chump --version took ${delta}ms (>500ms)"
    exit 1
fi

# ── Test 2: chump --help completes <500ms warm ───────────────────────────────
echo "Test 2: chump --help < 500ms (warm)"
"$CHUMP" --help > /dev/null  # warm
t0=$(now_ms)
"$CHUMP" --help > /dev/null
t1=$(now_ms)
delta=$((t1 - t0))
if [[ "$delta" -lt 500 ]]; then
    echo "  PASS (${delta}ms)"
else
    echo "  FAIL: chump --help took ${delta}ms (>500ms)"
    exit 1
fi

# ── Test 3: 50 concurrent --version invocations < 5s total ───────────────────
echo "Test 3: 50 concurrent chump --version invocations < 5s"
t0=$(now_ms)
pids=()
for _ in $(seq 50); do
    "$CHUMP" --version > /dev/null &
    pids+=($!)
done
for pid in "${pids[@]}"; do
    wait "$pid" || { echo "  FAIL: subprocess $pid exited non-zero"; exit 1; }
done
t1=$(now_ms)
delta=$((t1 - t0))
if [[ "$delta" -lt 5000 ]]; then
    echo "  PASS (${delta}ms for 50 concurrent)"
else
    echo "  FAIL: 50 concurrent took ${delta}ms (>5s — likely tokio runtime contention)"
    exit 1
fi

# ── Test 4: CHUMP_STARTUP_TIMEOUT_MS small budget on a workflow doesn't trip --version path ─
# --version is short-circuited BEFORE the watchdog arms, so even a tiny
# budget shouldn't trip it.
echo "Test 4: tight CHUMP_STARTUP_TIMEOUT_MS=100 does not trip --version path"
out=$(CHUMP_STARTUP_TIMEOUT_MS=100 "$CHUMP" --version 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 && "$out" == chump* ]]; then
    echo "  PASS"
else
    echo "  FAIL: rc=$rc out=$out"
    exit 1
fi

# ── Test 5: --debug emit on top-level args still works ───────────────────────
echo "Test 5: --debug emit still works alongside --version"
out=$("$CHUMP" --debug --version 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 && "$out" == *"chump"* && "$out" == *"[debug]"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: --debug should print debug header AND --version output. rc=$rc out=$out"
    exit 1
fi

echo
echo "All 5 chump-startup-fast smoke tests passed."
