#!/usr/bin/env bash
# scripts/ci/test-infra-watcher-pty-check.sh — RESILIENT-092
#
# Verifies infra-watcher's check-ptys subcommand detects pty pressure BEFORE
# forkpty actually fails (i.e. at a configurable threshold below 100%), emits
# a pty_exhaustion finding, and pages the operator via operator-recall.sh
# (kind=operator_recall condition=PTY_EXHAUSTION) — not just a silent log line.
#
# Cases:
#   1. Simulated 85/100 (85%) allocation, threshold=80 → pty_exhaustion finding
#      + operator_recall condition=PTY_EXHAUSTION, BEFORE alloc reaches limit.
#   2. Simulated 40/100 (40%) allocation → no finding, no recall (all-green).
#   3. Simulated 98/100 (98%) → severity=critical (not just warning).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOOP="${REPO_ROOT}/scripts/coord/infra-watcher-loop.sh"

PASS=0
FAIL=0

_setup_env() {
    local testdir
    testdir="$(mktemp -d)"
    mkdir -p "${testdir}/.chump-locks"
    printf '%s\n' "$testdir"
}

_run_check_ptys() {
    local testdir="$1" alloc="$2" limit="$3"
    env REPO_ROOT="$testdir" \
        CHUMP_PTY_ALLOC_OVERRIDE="$alloc" \
        CHUMP_PTY_LIMIT_OVERRIDE="$limit" \
        CHUMP_INFRA_WATCHER_PTY_THRESHOLD=80 \
        bash "$LOOP" check-ptys >/dev/null 2>&1 || true
}

test_pty_pressure_before_exhaustion() {
    local testdir
    testdir="$(_setup_env)"

    # 85/100 = 85% — over the 80% threshold, but nowhere near the 100/100
    # exhaustion point where forkpty would actually start failing.
    _run_check_ptys "$testdir" 85 100

    local amb="${testdir}/.chump-locks/ambient.jsonl"
    if grep -q '"category":"pty_exhaustion"' "$amb" 2>/dev/null; then
        printf 'PASS: Case 1a: 85%% allocation (threshold=80%%) → pty_exhaustion finding\n'
        PASS=$((PASS + 1))
    else
        printf 'FAIL: Case 1a: expected pty_exhaustion finding — log:\n' >&2
        cat "$amb" >&2 2>/dev/null || true
        FAIL=$((FAIL + 1))
    fi

    if grep -q '"kind":"operator_recall"' "$amb" 2>/dev/null && \
       grep -q '"condition":"PTY_EXHAUSTION"' "$amb" 2>/dev/null; then
        printf 'PASS: Case 1b: operator paged via operator_recall condition=PTY_EXHAUSTION\n'
        PASS=$((PASS + 1))
    else
        printf 'FAIL: Case 1b: expected operator_recall condition=PTY_EXHAUSTION — log:\n' >&2
        cat "$amb" >&2 2>/dev/null || true
        FAIL=$((FAIL + 1))
    fi

    if grep -q '"severity":"warning"' "$amb" 2>/dev/null; then
        printf 'PASS: Case 1c: 85%% fires warning (not critical) — headroom still exists\n'
        PASS=$((PASS + 1))
    else
        printf 'FAIL: Case 1c: expected severity=warning at 85%%\n' >&2
        FAIL=$((FAIL + 1))
    fi

    rm -rf "$testdir"
}

test_pty_all_green() {
    local testdir
    testdir="$(_setup_env)"

    # 40/100 = 40% — well under threshold.
    _run_check_ptys "$testdir" 40 100

    local amb="${testdir}/.chump-locks/ambient.jsonl"
    if grep -q '"category":"pty_exhaustion"' "$amb" 2>/dev/null; then
        printf 'FAIL: Case 2: unexpected pty_exhaustion finding at 40%%\n' >&2
        cat "$amb" >&2 2>/dev/null || true
        FAIL=$((FAIL + 1))
    else
        printf 'PASS: Case 2: 40%% allocation → no finding, no page\n'
        PASS=$((PASS + 1))
    fi

    rm -rf "$testdir"
}

test_pty_critical_severity() {
    local testdir
    testdir="$(_setup_env)"

    # 98/100 = 98% — deep into the danger zone, must escalate to critical.
    _run_check_ptys "$testdir" 98 100

    local amb="${testdir}/.chump-locks/ambient.jsonl"
    if grep -q '"category":"pty_exhaustion"' "$amb" 2>/dev/null && \
       grep -q '"severity":"critical"' "$amb" 2>/dev/null; then
        printf 'PASS: Case 3: 98%% allocation → severity=critical\n'
        PASS=$((PASS + 1))
    else
        printf 'FAIL: Case 3: expected pty_exhaustion severity=critical at 98%% — log:\n' >&2
        cat "$amb" >&2 2>/dev/null || true
        FAIL=$((FAIL + 1))
    fi

    rm -rf "$testdir"
}

printf '=== test-infra-watcher-pty-check.sh (RESILIENT-092) ===\n'
printf 'Loop script: %s\n\n' "$LOOP"

if [[ ! -f "$LOOP" ]]; then
    printf 'FATAL: loop script not found: %s\n' "$LOOP" >&2
    exit 1
fi

test_pty_pressure_before_exhaustion
test_pty_all_green
test_pty_critical_severity

printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
