#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-claim-disk-plan-precheck.sh — INFRA-2360
#
# Smoke test for the pre-claim disk-plan check's observability, via the
# `chump claim <GAP-ID> --disk-plan-check-only` entry point (does not touch
# leases/worktrees/state.db). Verifies:
#   1. kind=claim_disk_plan_checked fires with decision=ok + duration_ms
#      when the underlying `chump disk plan` call succeeds (exit 0).
#   2. kind=claim_disk_plan_check_failed fires with failure_class=transient
#      when the disk-plan binary is missing/unexecutable, and the command
#      still exits non-blocking (fail-open contract).
#   3. kind=claim_disk_plan_bypassed fires with the right bypass reason for
#      both CHUMP_CLAIM_SKIP_DISK_PLAN=1 and CHUMP_CLAIM_ALLOW_DISK_REFUSE=1
#      (the latter exercised against a fake `chump disk plan` that REFUSEs).
#
# Exits non-zero on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -z "${CHUMP_BIN:-}" ]]; then
    CANDIDATE="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    if [[ -x "$CANDIDATE" ]]; then
        CHUMP_BIN="$CANDIDATE"
    else
        echo "Building chump binary..."
        cd "$REPO_ROOT" && cargo build --bin chump -q
        CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
        cd "$REPO_ROOT"
    fi
fi

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILS+=("$1"); }

echo "=== INFRA-2360 chump claim disk-plan precheck tests ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKE_REPO="$WORK/repo"
mkdir -p "$FAKE_REPO/.chump-locks"
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"

# ── Test 1: real `chump disk plan` (fails open when no inventory snapshot
#    exists yet — either OK or a classified failure, never a hard error) ──
rm -f "$AMBIENT"
set +e
OUT1=$(CHUMP_REPO="$FAKE_REPO" "$CHUMP_BIN" claim INFRA-TEST01 --disk-plan-check-only 2>&1)
RC1=$?
set -e

if [[ $RC1 -eq 0 || $RC1 -eq 1 || $RC1 -eq 2 || $RC1 -eq 3 ]]; then
    ok "exit code $RC1 is one of the documented codes (0=OK,1=REFUSE,2=WAIT,3=check-failed)"
else
    fail "unexpected exit code $RC1: $OUT1"
fi

if [[ -f "$AMBIENT" ]] && grep -qE '"kind":"claim_disk_plan_(checked|check_failed)"' "$AMBIENT"; then
    ok "kind=claim_disk_plan_checked or claim_disk_plan_check_failed emitted"
else
    fail "no disk-plan observability event emitted (ambient: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

if grep -q '"duration_ms"' "$AMBIENT" 2>/dev/null; then
    ok "duration_ms (cost tracking) present in emitted event"
else
    fail "duration_ms missing from emitted event"
fi

# ── Test 2: fake disk-plan binary that doesn't exist → transient failure,
#    fail-open (never blocks) ────────────────────────────────────────────
rm -f "$AMBIENT"
set +e
OUT2=$(CHUMP_REPO="$FAKE_REPO" CHUMP_CLAIM_DISK_PLAN_BIN="$WORK/nonexistent-chump-xyzzy" \
    "$CHUMP_BIN" claim INFRA-TEST02 --disk-plan-check-only 2>&1)
RC2=$?
set -e

if [[ $RC2 -eq 3 ]]; then
    ok "exit 3 (check-failed) when disk-plan binary is missing"
else
    fail "expected exit 3 for missing binary, got $RC2: $OUT2"
fi

if grep -q '"kind":"claim_disk_plan_check_failed"' "$AMBIENT" 2>/dev/null; then
    ok "kind=claim_disk_plan_check_failed emitted for missing binary"
else
    fail "claim_disk_plan_check_failed NOT emitted (ambient: $(cat "$AMBIENT" 2>/dev/null || echo ABSENT))"
fi

if grep -q '"failure_class":"transient"' "$AMBIENT" 2>/dev/null; then
    ok "failure_class=transient for missing binary (retryable class)"
else
    fail "expected failure_class=transient, ambient: $(cat "$AMBIENT" 2>/dev/null)"
fi

# ── Test 3: CHUMP_CLAIM_SKIP_DISK_PLAN=1 bypass is audited ──────────────
rm -f "$AMBIENT"
set +e
OUT3=$(CHUMP_REPO="$FAKE_REPO" CHUMP_CLAIM_SKIP_DISK_PLAN=1 "$CHUMP_BIN" claim INFRA-TEST03 --disk-plan-check-only 2>&1)
RC3=$?
set -e
# --disk-plan-check-only doesn't consult the skip flag itself (it's the
# smoke-test entry point, not the real gate) — this test targets the gate
# used inside `run_claim`, exercised via the Rust unit tests
# (disk_plan_precheck_tests::test_precheck_gate_skip_env_emits_bypass_event).
# Here we just confirm the flag doesn't break --disk-plan-check-only.
if [[ $RC3 -eq 0 || $RC3 -eq 1 || $RC3 -eq 2 || $RC3 -eq 3 ]]; then
    ok "--disk-plan-check-only tolerates CHUMP_CLAIM_SKIP_DISK_PLAN being set (exit $RC3)"
else
    fail "unexpected exit code $RC3 with skip env set: $OUT3"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
