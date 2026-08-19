#!/usr/bin/env bash
# test-fleet-doctor-auth-probe.sh — CREDIBLE-119
#
# Verifies fleet-doctor-strict.sh's auth-probe check (check_auth_probe):
#   1. Both api-key and oauth invalid → fail, detail says "auth dead: both
#      paths rejected".
#   2. api-key invalid but oauth valid, mode=oauth (so oauth IS the active
#      path) → pass.
#   3. api-key invalid but oauth valid, mode=api-key (precedence trap: a
#      valid path exists but isn't the active one) → fail.
#   4. Both api-key and oauth ABSENT (no credentials configured at all) →
#      skip, not fail — that's a distinct pre-existing signal owned by
#      fleet_doctor_validate()'s presence checks, not this live-probe check.
#
# Proves the CREDIBLE-119 behavior: `chump fleet doctor` must exit non-zero
# when a LIVE authenticated probe rejects both credential paths, not just
# when credentials are absent (which is all fleet_doctor_validate() in
# src/auth.rs ever checked before this gap).
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"
PROBE="$REPO_ROOT/scripts/coord/auth-status.sh"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOCTOR" ]] || fail "fleet-doctor-strict.sh missing"
[[ -f "$PROBE" ]] || fail "auth-status.sh missing"

TMPDIR_BASE="$(mktemp -d -t test-fleet-doctor-auth-probe-XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Isolate the auth-status.sh cache so this test never reads/writes the
# operator's real cached verdict. Each sub-test gets its OWN cache file
# (rather than one shared path) so a prior sub-test's cached verdict never
# leaks into the next one — the fake env vars change the "credential" state
# between sub-tests without touching any real file auth-status.sh's
# cache-freshness check would notice.
# NOTE: next_cache() is invoked via $(...) command substitution, which runs
# in a subshell — any counter it increments internally would reset on every
# call. mktemp -u gives a fresh unique path with no shared-state footgun.
next_cache() { mktemp -u -t "auth-status-cache-XXXXXX" --tmpdir="$TMPDIR_BASE"; }

# Source the doctor script for direct function access (skips the full
# networked sweep — matches the FLEET_DOCTOR_SOURCED pattern used by the
# other fleet-doctor-strict.sh check tests).
export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"

last_status() { printf '%s' "${STATUSES[-1]:-}"; }
last_detail() { printf '%s' "${DETAILS[-1]:-}"; }

# ── Test 1: both api-key and oauth invalid → fail, "auth dead: both paths rejected" ─
CHUMP_AUTH_STATUS_CACHE="$(next_cache)" \
CHUMP_AUTH_STATUS_FAKE_OAUTH=invalid \
CHUMP_AUTH_STATUS_FAKE_APIKEY=invalid \
CHUMP_AUTH_STATUS_FAKE_MODE=auto \
    check_auth_probe
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"auth dead: both paths rejected"* ]]; then
    pass "both paths invalid → fail, detail says auth dead: both paths rejected"
else
    fail "expected fail/'auth dead: both paths rejected', got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 2: oauth valid + api-key invalid, mode=oauth (active path is valid) → pass ─
CHUMP_AUTH_STATUS_CACHE="$(next_cache)" \
CHUMP_AUTH_STATUS_FAKE_OAUTH=valid \
CHUMP_AUTH_STATUS_FAKE_APIKEY=invalid \
CHUMP_AUTH_STATUS_FAKE_MODE=oauth \
    check_auth_probe
if [[ "$(last_status)" == "pass" ]]; then
    pass "oauth valid + active path=oauth → pass"
else
    fail "expected pass when the active path is valid, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 3: oauth valid but api-key is the active (broken) path → fail (the trap) ──
CHUMP_AUTH_STATUS_CACHE="$(next_cache)" \
CHUMP_AUTH_STATUS_FAKE_OAUTH=valid \
CHUMP_AUTH_STATUS_FAKE_APIKEY=invalid \
CHUMP_AUTH_STATUS_FAKE_MODE=api-key \
    check_auth_probe
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"not the active path"* ]]; then
    pass "valid oauth but broken active api-key path → fail (precedence trap)"
else
    fail "expected fail/'not the active path', got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 4: no credentials configured at all → skip, not fail ───────────────
CHUMP_AUTH_STATUS_CACHE="$(next_cache)" \
CHUMP_AUTH_STATUS_FAKE_OAUTH=absent \
CHUMP_AUTH_STATUS_FAKE_APIKEY=absent \
CHUMP_AUTH_STATUS_FAKE_MODE=auto \
    check_auth_probe
if [[ "$(last_status)" == "skip" ]] && [[ "$(last_detail)" == *"no credentials configured"* ]]; then
    pass "no credentials at all → skip (not this check's signal to own)"
else
    fail "expected skip/'no credentials configured', got status=$(last_status) detail=$(last_detail)"
fi

echo "=== all fleet-doctor auth-probe tests passed ==="
