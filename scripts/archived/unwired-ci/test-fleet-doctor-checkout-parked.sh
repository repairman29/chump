#!/usr/bin/env bash
# test-fleet-doctor-checkout-parked.sh — RESILIENT-1512
#
# Verifies fleet-doctor-strict.sh's checkout-parked-off-main check
# (check_checkout_parked_off_main):
#   1. Checkout on `main` → pass, no marker left behind.
#   2. Checkout freshly switched to a non-main branch → pass ("just
#      detected", starts the staleness clock) — a brief rebase/claim
#      window must not page.
#   3. Checkout still on that same non-main branch after the configured
#      CHECKOUT_PARKED_STALE_S threshold has elapsed → fail, detail names
#      the branch + age, and a kind=checkout_parked_off_main event lands
#      in ambient.jsonl.
#   4. Switching to a DIFFERENT non-main branch resets the clock (no false
#      "stale" carried over from a prior branch).
#
# Reproduces the RESILIENT-1512 hub-node incident: a gap-store checkout
# sat on fix/apex-watchdog-skip-not-always-on for hours, invisible until a
# `chump gap ship` refused to close a gap whose PR had already merged.
# This test fails on a checkout without RESILIENT-1512's
# check_checkout_parked_off_main function (undefined function error).
set -uo pipefail

REPO_ROOT_REAL="$(git rev-parse --show-toplevel)"
DOCTOR="$REPO_ROOT_REAL/scripts/coord/fleet-doctor-strict.sh"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOCTOR" ]] || fail "fleet-doctor-strict.sh missing"

TMPDIR_BASE="$(mktemp -d -t test-fleet-doctor-checkout-parked-XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"

last_status() { printf '%s' "${STATUSES[-1]:-}"; }
last_detail() { printf '%s' "${DETAILS[-1]:-}"; }

FIXTURE="$TMPDIR_BASE/repo"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q --initial-branch=main
git -C "$FIXTURE" config user.email test@test.local
git -C "$FIXTURE" config user.name test
git -C "$FIXTURE" commit -q --allow-empty -m init

# ── Test 1: on main → pass, no marker ───────────────────────────────────────
REPO_ROOT="$FIXTURE"
check_checkout_parked_off_main
if [[ "$(last_status)" == "pass" ]] && [[ ! -f "$FIXTURE/.chump-locks/checkout-off-main.marker" ]]; then
    pass "checkout on main → pass, no marker"
else
    fail "expected pass + no marker on main, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 2: freshly switched to a feature branch → pass (clock starts) ─────
git -C "$FIXTURE" checkout -q -b fix/some-feature
REPO_ROOT="$FIXTURE"
CHECKOUT_PARKED_STALE_S=1 check_checkout_parked_off_main
if [[ "$(last_status)" == "pass" ]] && [[ "$(last_detail)" == *"just detected"* ]]; then
    pass "freshly off-main → pass, clock started"
else
    fail "expected pass/'just detected', got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 3: still on same branch past threshold → fail + ambient event ─────
sleep 2
AMB="$TMPDIR_BASE/ambient.jsonl"
REPO_ROOT="$FIXTURE"
CHUMP_AMBIENT_LOG="$AMB" CHECKOUT_PARKED_STALE_S=1 check_checkout_parked_off_main
if [[ "$(last_status)" == "fail" ]] \
    && [[ "$(last_detail)" == *"fix/some-feature"* ]] \
    && [[ "$(last_detail)" == *"gap ship proof-of-merge"* ]]; then
    pass "stale off-main → fail, detail names branch + impact"
else
    fail "expected fail naming fix/some-feature, got status=$(last_status) detail=$(last_detail)"
fi
if [[ -f "$AMB" ]] && grep -q '"kind":"checkout_parked_off_main"' "$AMB"; then
    pass "kind=checkout_parked_off_main written to ambient.jsonl"
else
    fail "expected kind=checkout_parked_off_main in $AMB"
fi

# ── Test 4: switching to a different branch resets the clock ───────────────
git -C "$FIXTURE" checkout -q -b fix/another-feature
REPO_ROOT="$FIXTURE"
CHECKOUT_PARKED_STALE_S=1 check_checkout_parked_off_main
if [[ "$(last_status)" == "pass" ]] && [[ "$(last_detail)" == *"just detected"* ]]; then
    pass "switching branches resets the staleness clock"
else
    fail "expected reset-clock pass, got status=$(last_status) detail=$(last_detail)"
fi

echo "=== all fleet-doctor checkout-parked-off-main tests passed ==="
