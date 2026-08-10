#!/usr/bin/env bash
# test-fleet-doctor-ops-defect.sh — RESILIENT-257
#
# Verifies fleet-doctor-strict.sh's ops-defect self-diagnosis check
# (check_ops_defect_selfdiag):
#   1. No defects → pass.
#   2. Broken daemon exit code → fail, no auto-file when CHUMP_OPS_DEFECT_AUTOFILE=0.
#   3. False-positive alert (operator_recall fired while fleet was shipping) → fail.
#   4. Real defect + autofile=1 → auto-files a VOA via `chump voice` (docs/gaps +
#      docs/voice written into an isolated CHUMP_REPO_ROOT, never the real repo).
#   5. Dedup — a VOA already filed for the same wedge_class within the dedup
#      window suppresses re-filing.
#
# This proves the RESILIENT-257 behavior and fails without it (the check
# function + auto-file wiring did not exist before this gap).
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOCTOR" ]] || fail "fleet-doctor-strict.sh missing"

TMPDIR_BASE="$(mktemp -d -t test-fleet-doctor-ops-defect-XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Source the doctor script for direct function access (skips the full networked sweep).
export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"

last_status() { printf '%s' "${STATUSES[-1]:-}"; }
last_detail() { printf '%s' "${DETAILS[-1]:-}"; }

# ── Test 1: no defects → pass ────────────────────────────────────────────────
AMB_EMPTY="$TMPDIR_BASE/ambient-empty.jsonl"
: > "$AMB_EMPTY"
OPS_DEFECT_DAEMON_STATUS_CMD="true" \
CHUMP_AMBIENT_LOG="$AMB_EMPTY" \
    check_ops_defect_selfdiag
if [[ "$(last_status)" == "pass" ]]; then
    pass "no defects → pass"
else
    fail "expected pass with no defects, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 2: broken daemon exit code → fail (report-only, no autofile) ───────
CHUMP_OPS_DEFECT_AUTOFILE=0 \
OPS_DEFECT_DAEMON_STATUS_CMD='printf "com.chump.testdaemon\t127\n"' \
CHUMP_AMBIENT_LOG="$AMB_EMPTY" \
    check_ops_defect_selfdiag
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"broken-daemon-exit"* ]]; then
    pass "broken daemon exit code → fail, detail names broken-daemon-exit"
else
    fail "expected fail/broken-daemon-exit, got status=$(last_status) detail=$(last_detail)"
fi
if [[ "$(last_detail)" == *"auto-filed"* ]]; then
    fail "CHUMP_OPS_DEFECT_AUTOFILE=0 must not auto-file a VOA"
fi
pass "autofile=0 does not file a VOA"

# ── Test 3: false-positive alert (operator_recall fired while fleet shipped) ─
AMB_ALERT="$TMPDIR_BASE/ambient-alert.jsonl"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"operator_recall","condition":"AUTH_DEAD","reason":"fleet_auth_storm threshold"}\n' \
    "$now_iso" > "$AMB_ALERT"
CHUMP_OPS_DEFECT_AUTOFILE=0 \
OPS_DEFECT_DAEMON_STATUS_CMD="true" \
CHUMP_AMBIENT_LOG="$AMB_ALERT" \
OPS_DEFECT_SHIP_COUNT_OVERRIDE=5 \
    check_ops_defect_selfdiag
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"false-positive-alert"* ]] && [[ "$(last_detail)" == *"AUTH_DEAD"* ]]; then
    pass "operator_recall fired while shipping → fail, detail names false-positive-alert"
else
    fail "expected fail/false-positive-alert/AUTH_DEAD, got status=$(last_status) detail=$(last_detail)"
fi

# Sanity: same alert but ZERO ship-rate (fleet genuinely idle) → not a false
# positive by this check's definition → pass.
CHUMP_OPS_DEFECT_AUTOFILE=0 \
OPS_DEFECT_DAEMON_STATUS_CMD="true" \
CHUMP_AMBIENT_LOG="$AMB_ALERT" \
OPS_DEFECT_SHIP_COUNT_OVERRIDE=0 \
    check_ops_defect_selfdiag
if [[ "$(last_status)" == "pass" ]]; then
    pass "alert with zero ship-rate ground truth → not flagged as false-positive"
else
    fail "expected pass when ship-rate is genuinely zero, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 4: real defect + autofile=1 → auto-files a VOA (isolated repo root) ─
FAKE_REPO="$TMPDIR_BASE/fake-repo"
mkdir -p "$FAKE_REPO/docs/gaps" "$FAKE_REPO/docs/voice"
if ! command -v chump &>/dev/null; then
    echo "SKIP: chump binary not on PATH — cannot exercise live auto-file path" >&2
else
    AMB_ISOLATED="$TMPDIR_BASE/ambient-isolated.jsonl"
    : > "$AMB_ISOLATED"
    CHUMP_OPS_DEFECT_AUTOFILE=1 \
    OPS_DEFECT_DAEMON_STATUS_CMD='printf "com.chump.testdaemon\t127\n"' \
    CHUMP_AMBIENT_LOG="$AMB_ISOLATED" \
    CHUMP_REPO_ROOT="$FAKE_REPO" \
    CHUMP_VOICE_TEST_ID="VOA-TEST257" \
        check_ops_defect_selfdiag
    if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"auto-filed"* ]]; then
        pass "real defect + autofile=1 → detail reports auto-filed"
    else
        fail "expected auto-filed in detail, got status=$(last_status) detail=$(last_detail)"
    fi
    if [[ -f "$FAKE_REPO/docs/gaps/VOA-TEST257.yaml" && -f "$FAKE_REPO/docs/voice/VOA-TEST257-FULL.yaml" ]]; then
        pass "chump voice wrote docs/gaps/VOA-TEST257.yaml and docs/voice/VOA-TEST257-FULL.yaml"
    else
        fail "expected VOA-TEST257 yaml files under $FAKE_REPO, not found"
    fi
    if grep -q '"kind":"voice_of_agent_filed"' "$AMB_ISOLATED" 2>/dev/null; then
        pass "voice_of_agent_filed emitted to isolated ambient log"
    else
        fail "expected kind=voice_of_agent_filed in $AMB_ISOLATED"
    fi

    # ── Test 5: dedup — same wedge_class already filed → skip re-filing ─────
    CHUMP_OPS_DEFECT_AUTOFILE=1 \
    OPS_DEFECT_DAEMON_STATUS_CMD='printf "com.chump.testdaemon\t127\n"' \
    CHUMP_AMBIENT_LOG="$AMB_ISOLATED" \
    CHUMP_REPO_ROOT="$FAKE_REPO" \
    CHUMP_VOICE_TEST_ID="VOA-TEST257B" \
        check_ops_defect_selfdiag
    if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"already filed"* ]]; then
        pass "dedup suppresses re-filing within window"
    else
        fail "expected 'already filed' dedup message, got status=$(last_status) detail=$(last_detail)"
    fi
    if [[ -f "$FAKE_REPO/docs/gaps/VOA-TEST257B.yaml" ]]; then
        fail "dedup should have prevented a second VOA-TEST257B.yaml from being written"
    fi
    pass "no second VOA file written on dedup"
fi

echo "=== all ops-defect self-diagnosis tests passed ==="
