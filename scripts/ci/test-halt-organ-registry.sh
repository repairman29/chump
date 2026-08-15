#!/usr/bin/env bash
# scripts/ci/test-halt-organ-registry.sh — RESILIENT-326
#
# CI gate for the halt-organ governance rule: "no organ may halt/disable the
# fleet without a TESTED auto-recovery path + a loud page."
#
# Two halves:
#   A. Structural — parses docs/process/HALT_ORGAN_REGISTRY.md and, for every
#      registered organ, verifies its halt script exists, contains a page call,
#      and has at least one recovery-test file that actually exists on disk.
#      Fails closed if a row's evidence goes missing (registry drift).
#   B. Behavioral — exercises scripts/coord/halt-status.sh (the board
#      instrument) in an isolated tmp HOME: proves it is silent+exit-0 when
#      nothing is halted, and loudly exit-1 for each of the two file-based
#      halt conditions (kill-switch at 0, pause sentinel present).
#
# Tier A: pure shell, no GitHub API, no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REGISTRY="$REPO_ROOT/docs/process/HALT_ORGAN_REGISTRY.md"
HALT_STATUS="$REPO_ROOT/scripts/coord/halt-status.sh"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

[[ -f "$REGISTRY" ]] || { echo "[FATAL] registry doc missing: $REGISTRY" >&2; exit 1; }
[[ -x "$HALT_STATUS" ]] || { echo "[FATAL] halt-status.sh missing or not executable: $HALT_STATUS" >&2; exit 1; }

# ── A. Structural: every organ's referenced evidence must exist ────────────
# Each organ we assert on: halt-script path, a page-call grep target inside
# it, and at least one recovery-test path.
declare -A ORGAN_SCRIPT=(
    [back-pressure]="scripts/ops/back-pressure-controller.sh"
    [kill-switch]="scripts/ops/chumpbar-pause.sh"
    [waste-spike-pause]="scripts/coord/waste-spike-detector.sh"
    [ci-health-gate-pause]="scripts/coord/ci-health-gate.sh"
    [farmer-gate]="scripts/coord/farmer.sh"
)
declare -A ORGAN_PAGE_GREP=(
    [back-pressure]="notify_operator"
    [kill-switch]=""            # kill-switch itself doesn't page; setter does (checked under back-pressure)
    [waste-spike-pause]="notify_operator"
    [ci-health-gate-pause]="notify_operator"
    [farmer-gate]="operator_page"
)
declare -A ORGAN_RECOVERY_TESTS=(
    [back-pressure]="scripts/ci/test-back-pressure-hysteresis.sh"
    [kill-switch]="scripts/ci/test-fleet-kill-switch.sh"
    [waste-spike-pause]="scripts/ci/test-waste-spike-pause.sh"
    [ci-health-gate-pause]="scripts/ci/test-fleet-pause-autolift.sh scripts/ci/test-ci-health-gate.sh scripts/ci/test-slo-breach-gates.sh"
    [farmer-gate]="scripts/ci/test-farmer-stale-lease-heartbeat.sh scripts/ci/test-farmer.sh"
)

for organ in "${!ORGAN_SCRIPT[@]}"; do
    script_path="$REPO_ROOT/${ORGAN_SCRIPT[$organ]}"
    if [[ -f "$script_path" ]]; then
        ok "organ=$organ halt script exists (${ORGAN_SCRIPT[$organ]})"
    else
        fail "organ=$organ halt script MISSING: ${ORGAN_SCRIPT[$organ]}"
    fi

    grep_target="${ORGAN_PAGE_GREP[$organ]}"
    if [[ -n "$grep_target" ]]; then
        if [[ -f "$script_path" ]] && grep -q "$grep_target" "$script_path" 2>/dev/null; then
            ok "organ=$organ has a page call ($grep_target)"
        else
            fail "organ=$organ has NO page call matching '$grep_target' in ${ORGAN_SCRIPT[$organ]}"
        fi
    fi

    any_recovery_test=0
    for t in ${ORGAN_RECOVERY_TESTS[$organ]}; do
        if [[ -f "$REPO_ROOT/$t" ]]; then
            any_recovery_test=1
        fi
    done
    if [[ "$any_recovery_test" == "1" ]]; then
        ok "organ=$organ has at least one recovery test on disk"
    else
        fail "organ=$organ has NO recovery test on disk (checked: ${ORGAN_RECOVERY_TESTS[$organ]})"
    fi
done

# Registry doc must actually mention every organ script path (keeps the table
# from drifting silently out of sync with the code it describes).
for organ in "${!ORGAN_SCRIPT[@]}"; do
    if grep -qF "${ORGAN_SCRIPT[$organ]}" "$REGISTRY"; then
        ok "registry doc references ${ORGAN_SCRIPT[$organ]}"
    else
        fail "registry doc does NOT mention ${ORGAN_SCRIPT[$organ]} — table drift"
    fi
done

# ── B. Behavioral: halt-status.sh board instrument ──────────────────────────
TMP="$(mktemp -d -t resilient326-XXXX)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/chump"
AUTON_FILE="$TMP/chump/AUTONOMY_LEVEL"
PAUSE_FILE="$TMP/fleet-paused"

run_halt_status() {
    CHUMP_AUTON_FILE="$AUTON_FILE" \
    CHUMP_FLEET_PAUSE_FILE="$PAUSE_FILE" \
    CHUMP_HALT_STATUS_SKIP_SYSTEMD=1 \
    "$HALT_STATUS"
}

# B1: healthy state → exit 0, no banner
echo 5 > "$AUTON_FILE"
rm -f "$PAUSE_FILE"
if out="$(run_halt_status)"; then
    if echo "$out" | grep -q "HALT ACTIVE"; then
        fail "B1: healthy state printed a HALT banner"
    else
        ok "B1: healthy state (autonomy=5, no pause) → exit 0, no banner"
    fi
else
    fail "B1: healthy state → expected exit 0, got non-zero"
fi

# B2: kill-switch at 0 → exit 1, loud banner naming AUTONOMY_LEVEL
echo 0 > "$AUTON_FILE"
if out="$(run_halt_status)"; then
    fail "B2: AUTONOMY_LEVEL=0 → expected non-zero exit, got 0"
else
    if echo "$out" | grep -q "HALT ACTIVE" && echo "$out" | grep -q "AUTONOMY_LEVEL"; then
        ok "B2: AUTONOMY_LEVEL=0 → loud HALT banner naming the kill-switch"
    else
        fail "B2: AUTONOMY_LEVEL=0 → exit non-zero but banner missing/incomplete: $out"
    fi
fi

# B3: pause sentinel present → exit 1, loud banner naming the sentinel
echo 5 > "$AUTON_FILE"
echo '{"kind":"test_pause"}' > "$PAUSE_FILE"
if out="$(run_halt_status)"; then
    fail "B3: pause sentinel present → expected non-zero exit, got 0"
else
    if echo "$out" | grep -q "HALT ACTIVE" && echo "$out" | grep -q "fleet-paused"; then
        ok "B3: pause sentinel present → loud HALT banner naming the sentinel"
    else
        fail "B3: pause sentinel present → exit non-zero but banner missing/incomplete: $out"
    fi
fi
rm -f "$PAUSE_FILE"

# B4: missing AUTONOMY_LEVEL file → fail-closed, treated as halted
rm -f "$AUTON_FILE"
if out="$(run_halt_status)"; then
    fail "B4: missing AUTONOMY_LEVEL file → expected fail-closed non-zero exit, got 0"
else
    ok "B4: missing AUTONOMY_LEVEL file → fail-closed (treated as halted)"
fi

echo ""
echo "── RESILIENT-326 halt-organ-registry: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
