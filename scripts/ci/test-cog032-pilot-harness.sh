#!/usr/bin/env bash
# test-cog032-pilot-harness.sh — INFRA-393 — smoke test the pilot harness
#
# Verifies --dry-run mode prints the expected plan + env-var matrix without
# executing claude. Doesn't run real trials (those need a live Anthropic
# API key + 90 min wall-clock × N).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$REPO_ROOT/scripts/ab-harness/run-cog032-pilot.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# ── Test 1: --cell A produces CHUMP_LESSONS_AT_SPAWN_N=0 ──────────────────
echo "[test-1] --cell A maps to CHUMP_LESSONS_AT_SPAWN_N=0 (lessons-off control)"
out=$("$HARNESS" --cell A --n 2 --dry-run 2>&1 || true)
if ! grep -q "CHUMP_LESSONS_AT_SPAWN_N=0" <<<"$out"; then
    echo "FAIL: cell A should set CHUMP_LESSONS_AT_SPAWN_N=0" >&2
    echo "$out" >&2
    exit 1
fi
if ! grep -q "CHUMP_BENCH_CELL=A" <<<"$out"; then
    echo "FAIL: cell A should set CHUMP_BENCH_CELL=A" >&2
    exit 1
fi
echo "  PASS"

# ── Test 2: --cell B produces CHUMP_LESSONS_AT_SPAWN_N=5 (treatment) ──────
echo "[test-2] --cell B maps to CHUMP_LESSONS_AT_SPAWN_N=5 (lessons-on)"
out=$("$HARNESS" --cell B --n 2 --dry-run 2>&1 || true)
if ! grep -q "CHUMP_LESSONS_AT_SPAWN_N=5" <<<"$out"; then
    echo "FAIL: cell B should set CHUMP_LESSONS_AT_SPAWN_N=5" >&2
    exit 1
fi
echo "  PASS"

# ── Test 3: dry-run enumerates n trials with CHUMP_BENCH_MODE=1 ───────────
echo "[test-3] dry-run plan enumerates n=3 trials, each with CHUMP_BENCH_MODE=1"
out=$("$HARNESS" --cell A --n 3 --dry-run 2>&1 || true)
trial_count=$(grep -c "trial [0-9]* / 3" <<<"$out" || true)
if [[ "$trial_count" -ne 3 ]]; then
    echo "FAIL: expected 3 trial blocks, got $trial_count" >&2
    echo "$out" >&2
    exit 1
fi
bench_mode_count=$(grep -c "CHUMP_BENCH_MODE=1" <<<"$out" || true)
if [[ "$bench_mode_count" -lt 3 ]]; then
    echo "FAIL: expected ≥3 CHUMP_BENCH_MODE=1 lines, got $bench_mode_count" >&2
    exit 1
fi
echo "  PASS: 3 trials enumerated, all bench-mode"

# ── Test 4: invalid --cell rejected ───────────────────────────────────────
echo "[test-4] invalid --cell rejected"
if "$HARNESS" --cell Z --n 1 --dry-run 2>/dev/null; then
    echo "FAIL: --cell Z should be rejected" >&2
    exit 1
fi
echo "  PASS"

# ── Test 5: missing --cell rejected ───────────────────────────────────────
echo "[test-5] missing --cell rejected"
if "$HARNESS" --n 1 --dry-run 2>/dev/null; then
    echo "FAIL: missing --cell should exit 2" >&2
    exit 1
fi
echo "  PASS"

# ── Test 6: round-robin task selection (n > task_count) ───────────────────
echo "[test-6] round-robin task selection when n > task_count"
# Bench v0.1 has 5 tasks; ask for n=7 trials, verify task IDs cycle
out=$("$HARNESS" --cell A --n 7 --dry-run 2>&1 || true)
distinct_tasks=$(grep -oE "task cog032-T[0-9]+" <<<"$out" | sort -u | wc -l | tr -d ' ')
total_trial_lines=$(grep -c "trial [0-9]* / 7" <<<"$out" || true)
if [[ "$total_trial_lines" -ne 7 ]]; then
    echo "FAIL: expected 7 trial blocks, got $total_trial_lines" >&2
    exit 1
fi
# Bench has 5 tasks → with n=7, distinct ≤ 5
if [[ "$distinct_tasks" -gt 5 ]]; then
    echo "FAIL: should round-robin within 5-task bench, got $distinct_tasks distinct" >&2
    exit 1
fi
echo "  PASS: 7 trials drawn from $distinct_tasks distinct tasks (≤ 5)"

echo
echo "PASS: INFRA-393 pilot harness smoke tests all green"
