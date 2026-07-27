#!/usr/bin/env bash
# test-operator-page.sh — INFRA-1774: operator-page protocol coverage.
#
# Smoke test command (per AC 4): bash scripts/ci/test-operator-page.sh

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PAGE_SCRIPT="$REPO_ROOT/scripts/dispatch/operator-page.sh"

if [[ ! -x "$PAGE_SCRIPT" ]]; then
    echo "FAIL: $PAGE_SCRIPT not found or not executable" >&2
    exit 1
fi

_pass=0
_fail=0

_ok()   { echo "  ✓ $*"; (( _pass++ )) || true; }
_fail() { echo "  ✗ FAIL: $*" >&2; (( _fail++ )) || true; }

_dir="$(mktemp -d)"
_amb="$_dir/ambient.jsonl"
trap 'rm -rf "$_dir"' EXIT

# ── Test 1: raise a page with each severity tier ─────────────────────────────
echo "Test 1: raise pages across severity tiers..."
for sev in info action block; do
    if CHUMP_AMBIENT_LOG="$_amb" REPO_ROOT="$REPO_ROOT" \
        "$PAGE_SCRIPT" --severity "$sev" --title "t-$sev" --message "m-$sev" --gap-id INFRA-1774 >/dev/null; then
        _ok "raised severity=$sev"
    else
        _fail "failed to raise severity=$sev"
    fi
done
grep -c '"kind":"operator_page"' "$_amb" | grep -q 3 && _ok "3 operator_page events written" \
    || _fail "expected 3 operator_page events"

# ── Test 2: invalid severity is a permanent failure (exit 1) ─────────────────
echo "Test 2: invalid severity rejected..."
set +e
CHUMP_AMBIENT_LOG="$_amb" REPO_ROOT="$REPO_ROOT" \
    "$PAGE_SCRIPT" --severity bogus --title x --message y >/dev/null 2>&1
_rc=$?
set -e
[[ $_rc -eq 1 ]] && _ok "invalid severity exits 1 (permanent)" || _fail "expected exit 1, got $_rc"

# ── Test 3: ack a raised page, pending sweep no longer sees it ───────────────
echo "Test 3: ack a raised page..."
CHUMP_AMBIENT_LOG="$_amb" REPO_ROOT="$REPO_ROOT" \
    "$PAGE_SCRIPT" --severity action --title ackme --message "please ack" >/dev/null
_corr="$(grep '"title":"ackme"' "$_amb" | tail -1 | grep -o '"corr_id":"[^"]*"' | head -1 | sed -E 's/"corr_id":"([^"]*)"/\1/')"
if [[ -n "$_corr" ]]; then
    _ok "extracted corr_id=$_corr"
else
    _fail "could not extract corr_id from raised event"
fi

if CHUMP_AMBIENT_LOG="$_amb" REPO_ROOT="$REPO_ROOT" \
    "$PAGE_SCRIPT" --ack "$_corr" --ack-by "test-harness" >/dev/null; then
    _ok "ack succeeded"
else
    _fail "ack failed"
fi
grep -q "\"kind\":\"operator_page_ack\".*\"corr_id\":\"$_corr\"" "$_amb" && _ok "operator_page_ack written" \
    || _fail "operator_page_ack not found in ambient log"

# ── Test 4: ack of unknown corr_id is a permanent failure ────────────────────
echo "Test 4: ack of unknown corr_id rejected..."
set +e
CHUMP_AMBIENT_LOG="$_amb" REPO_ROOT="$REPO_ROOT" \
    "$PAGE_SCRIPT" --ack "never-raised-corr-id" >/dev/null 2>&1
_rc=$?
set -e
[[ $_rc -eq 1 ]] && _ok "unknown corr_id exits 1 (permanent)" || _fail "expected exit 1, got $_rc"

# ── Test 5: --check-timeouts emits operator_page_timeout past deadline ───────
echo "Test 5: timeout sweep..."
_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_past_epoch=$(( $(date -u +%s) - 3600 ))
printf '{"ts":"%s","kind":"operator_page","corr_id":"op-timeout-test","severity":"block","title":"t","message":"m","gap_id":"","timeout_secs":60,"raised_epoch":%s,"cost_usd_at_page":"unknown"}\n' \
    "$_ts" "$_past_epoch" >> "$_amb"

CHUMP_AMBIENT_LOG="$_amb" REPO_ROOT="$REPO_ROOT" "$PAGE_SCRIPT" --check-timeouts >/dev/null
grep -q "\"kind\":\"operator_page_timeout\".*\"corr_id\":\"op-timeout-test\"" "$_amb" && _ok "timeout event emitted" \
    || _fail "expected operator_page_timeout for op-timeout-test"

echo
echo "── Summary: $_pass passed, $_fail failed ──"
[[ $_fail -eq 0 ]]
