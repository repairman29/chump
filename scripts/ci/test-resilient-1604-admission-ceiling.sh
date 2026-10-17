#!/usr/bin/env bash
# test-resilient-1604-admission-ceiling.sh — RESILIENT-1604
#
# Proves the node-wide admission ceiling defers spawns when the live
# process-table count is at/above the ceiling, proceeds once it clears, and
# fails open (admits anyway) if the ceiling never clears within the bound —
# using a fake process-count fixture file instead of real `claude -p` /
# cargo processes. Also proves fleet-doctor-strict.sh's check_admission_ceiling
# goes RED when live counts exceed the configured ceiling.
#
# Reproduces the cuphead incident (4 cores, 5-8 concurrent `claude -p` + up
# to 9 cargo jobs at load 12-18, 2026-10-16) that budget-killed agents which
# had already finished their work.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/coord/lib/admission-gate.sh"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$LIB" ]] || fail "admission-gate.sh missing"
[[ -f "$DOCTOR" ]] || fail "fleet-doctor-strict.sh missing"

TMPDIR_BASE="$(mktemp -d -t test-resilient-1604-XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# shellcheck disable=SC1090
source "$LIB"

AMB="$TMPDIR_BASE/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMB"

count_admission_deferred() {
    grep -c '"kind":"admission_deferred"' "$AMB" 2>/dev/null || echo 0
}

# ── Test 1: below ceiling → admits immediately, no deferral emitted ────────
CHUMP_ADMISSION_TEST_CLAUDE_COUNT=1 CHUMP_MAX_CONCURRENT_CLAUDE=4 \
    chump_admission_wait_claude
if [[ "$(count_admission_deferred)" == "0" ]]; then
    pass "below ceiling: no admission_deferred emitted"
else
    fail "expected 0 admission_deferred events, got $(count_admission_deferred)"
fi

# ── Test 2: at/above ceiling, fixture clears before timeout → deferred once,
#            then admitted (fixture file simulates the live count dropping) ─
FIXTURE="$TMPDIR_BASE/claude_count"
echo 5 > "$FIXTURE"
# Flip the fixture to a clearing value in the background, mid-wait — models
# an external process table changing over time without real claude -p procs.
( sleep 3; echo 1 > "$FIXTURE" ) &
_bg_pid=$!

: > "$AMB"
start_ts=$(date +%s)
CHUMP_ADMISSION_TEST_CLAUDE_COUNT_FILE="$FIXTURE" CHUMP_MAX_CONCURRENT_CLAUDE=4 \
    CHUMP_ADMISSION_WAIT_TIMEOUT_S=30 CHUMP_ADMISSION_POLL_INTERVAL_S=1 \
    chump_admission_wait_claude
end_ts=$(date +%s)
wait "$_bg_pid" 2>/dev/null || true

if [[ "$(count_admission_deferred)" -ge "1" ]] \
    && grep -q '"kind":"admission_deferred".*"outcome":"deferred"' "$AMB" \
    && ! grep -q '"outcome":"fail_open_timeout"' "$AMB"; then
    pass "ceiling clears before timeout: deferred once, no fail-open timeout, $(( end_ts - start_ts ))s elapsed"
else
    fail "expected a clean deferral+clear, got: $(cat "$AMB")"
fi

# ── Test 3: ceiling never clears within the bound → fails open, still
#            returns (doesn't hang), and records fail_open_timeout ─────────
echo 9 > "$FIXTURE"   # cuphead receipt: up to 9 concurrent against a small ceiling
: > "$AMB"
start_ts=$(date +%s)
CHUMP_ADMISSION_TEST_CLAUDE_COUNT_FILE="$FIXTURE" CHUMP_MAX_CONCURRENT_CLAUDE=2 \
    CHUMP_ADMISSION_WAIT_TIMEOUT_S=3 CHUMP_ADMISSION_POLL_INTERVAL_S=1 \
    chump_admission_wait_claude
rc=$?
end_ts=$(date +%s)
elapsed=$(( end_ts - start_ts ))

if [[ "$rc" == "0" ]] && grep -q '"outcome":"fail_open_timeout"' "$AMB" && (( elapsed <= 10 )); then
    pass "ceiling never clears: fails open within bound (${elapsed}s), outcome=fail_open_timeout recorded"
else
    fail "expected fail-open within bound, got rc=$rc elapsed=${elapsed}s ambient=$(cat "$AMB")"
fi

# ── Test 4: cargo resource uses its own ceiling/count seam independently ───
: > "$AMB"
CHUMP_ADMISSION_TEST_CARGO_COUNT=9 CHUMP_MAX_CONCURRENT_CARGO_JOBS=2 \
    CHUMP_ADMISSION_WAIT_TIMEOUT_S=2 CHUMP_ADMISSION_POLL_INTERVAL_S=1 \
    chump_admission_wait_cargo
if grep -q '"resource":"cargo"' "$AMB" && grep -q '"outcome":"fail_open_timeout"' "$AMB"; then
    pass "cargo resource gates independently of claude"
else
    fail "expected cargo-resource deferral, got: $(cat "$AMB")"
fi

# ── Test 5: default ceiling derives from nproc when no env override set ───
unset CHUMP_MAX_CONCURRENT_CLAUDE
_cores_for_test="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
_expected=$(( _cores_for_test / 2 ))
(( _expected < 1 )) && _expected=1
_got="$(chump_admission_ceiling_claude)"
if [[ "$_got" == "$_expected" ]]; then
    pass "default ceiling = max(1, nproc/2) = $_expected"
else
    fail "expected default ceiling $_expected, got $_got"
fi

# ── Test 6: fleet-doctor's check_admission_ceiling goes RED on breach ──────
export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"

last_status() { printf '%s' "${STATUSES[-1]:-}"; }
last_detail() { printf '%s' "${DETAILS[-1]:-}"; }

CHUMP_ADMISSION_TEST_CLAUDE_COUNT=8 CHUMP_MAX_CONCURRENT_CLAUDE=1 \
    CHUMP_ADMISSION_TEST_CARGO_COUNT=1 CHUMP_MAX_CONCURRENT_CARGO_JOBS=4 \
    check_admission_ceiling
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"claude: 8 active > ceiling 1"* ]]; then
    pass "fleet-doctor RED on admission-ceiling breach: $(last_detail)"
else
    fail "expected fail status naming the breach, got status=$(last_status) detail=$(last_detail)"
fi

CHUMP_ADMISSION_TEST_CLAUDE_COUNT=1 CHUMP_MAX_CONCURRENT_CLAUDE=4 \
    CHUMP_ADMISSION_TEST_CARGO_COUNT=1 CHUMP_MAX_CONCURRENT_CARGO_JOBS=4 \
    check_admission_ceiling
if [[ "$(last_status)" == "pass" ]]; then
    pass "fleet-doctor passes when under ceiling: $(last_detail)"
else
    fail "expected pass under ceiling, got status=$(last_status) detail=$(last_detail)"
fi

echo "=== all RESILIENT-1604 admission-ceiling tests passed ==="
