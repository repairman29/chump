#!/usr/bin/env bash
# test-fleet-doctor-tracked-config-drift.sh — RESILIENT-1106
#
# Verifies fleet-doctor-strict.sh's tracked-config-drift check
# (check_tracked_config_drift):
#   1. A live, git-untracked file hard-sets a var that a tracked
#      scripts/setup/*.env config-as-code file also declares (via bash
#      default-assignment `: "${VAR:=value}"`), to a DIFFERENT literal value
#      → fail, detail names the var + both values + both file paths, and a
#      kind=tracked_config_drift event is appended to ambient.jsonl.
#   2. The live file agrees with the tracked value → pass.
#   3. No live override files exist at all → skip, not fail (nothing outside
#      git to drift from — most checkouts have no per-node launcher).
#
# Proves the RESILIENT-1106 behavior: #4593 pulled worker self-heal policy
# into tracked config-as-code, but a hand-deployed, untracked node launcher
# can still silently override the SAME var to a different value and win at
# runtime. Without this check, that class of drift is invisible until it
# causes an incident (as the untracked-launcher case did on 2026-09-08,
# pre-#4593). This test fails on a checkout without RESILIENT-1106's
# check_tracked_config_drift function (undefined function error).
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOCTOR" ]] || fail "fleet-doctor-strict.sh missing"

TMPDIR_BASE="$(mktemp -d -t test-fleet-doctor-config-drift-XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

mkdir -p "$TMPDIR_BASE/tracked" "$TMPDIR_BASE/live"

export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"

last_status() { printf '%s' "${STATUSES[-1]:-}"; }
last_detail() { printf '%s' "${DETAILS[-1]:-}"; }

# ── Test 1: live file hard-overrides a tracked var to a different value → fail ──
cat > "$TMPDIR_BASE/tracked/worker-policy.env" <<'EOF'
: "${CHUMP_STARVE_AUTO_RELAX:=1}"
export CHUMP_STARVE_AUTO_RELAX
: "${CHUMP_STARVE_AUTO_SHUTDOWN:=0}"
export CHUMP_STARVE_AUTO_SHUTDOWN
EOF
cat > "$TMPDIR_BASE/live/node1-worker-run.sh" <<'EOF'
#!/usr/bin/env bash
export CHUMP_STARVE_AUTO_RELAX=0
EOF
AMB1="$TMPDIR_BASE/ambient1.jsonl"

CHUMP_CONFIG_DRIFT_TRACKED_GLOB="$TMPDIR_BASE/tracked/*.env" \
CHUMP_CONFIG_DRIFT_LIVE_GLOB="$TMPDIR_BASE/live/*.sh" \
CHUMP_AMBIENT_LOG="$AMB1" \
    check_tracked_config_drift

if [[ "$(last_status)" == "fail" ]] \
    && [[ "$(last_detail)" == *"CHUMP_STARVE_AUTO_RELAX"* ]] \
    && [[ "$(last_detail)" == *"tracked="* ]] \
    && [[ "$(last_detail)" == *"live="* ]]; then
    pass "drifted var → fail, detail names var + tracked/live values"
else
    fail "expected fail naming CHUMP_STARVE_AUTO_RELAX, got status=$(last_status) detail=$(last_detail)"
fi

if [[ -f "$AMB1" ]] && grep -q '"kind":"tracked_config_drift"' "$AMB1"; then
    pass "kind=tracked_config_drift written to ambient.jsonl"
else
    fail "expected kind=tracked_config_drift in $AMB1"
fi

# ── Test 2: live file agrees with tracked value → pass ─────────────────────
cat > "$TMPDIR_BASE/live/node1-worker-run.sh" <<'EOF'
#!/usr/bin/env bash
export CHUMP_STARVE_AUTO_RELAX=1
EOF
AMB2="$TMPDIR_BASE/ambient2.jsonl"

CHUMP_CONFIG_DRIFT_TRACKED_GLOB="$TMPDIR_BASE/tracked/*.env" \
CHUMP_CONFIG_DRIFT_LIVE_GLOB="$TMPDIR_BASE/live/*.sh" \
CHUMP_AMBIENT_LOG="$AMB2" \
    check_tracked_config_drift

if [[ "$(last_status)" == "pass" ]]; then
    pass "live value matches tracked value → pass"
else
    fail "expected pass when live agrees with tracked, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 3: no live override files present at all → skip, not fail ─────────
CHUMP_CONFIG_DRIFT_TRACKED_GLOB="$TMPDIR_BASE/tracked/*.env" \
CHUMP_CONFIG_DRIFT_LIVE_GLOB="$TMPDIR_BASE/does-not-exist/*.sh" \
CHUMP_AMBIENT_LOG="$TMPDIR_BASE/ambient3.jsonl" \
    check_tracked_config_drift

if [[ "$(last_status)" == "skip" ]] && [[ "$(last_detail)" == *"nothing outside git to drift from"* ]]; then
    pass "no live override files → skip (not this node's failure to report)"
else
    fail "expected skip/'nothing outside git to drift from', got status=$(last_status) detail=$(last_detail)"
fi

echo "=== all fleet-doctor tracked-config-drift tests passed ==="
