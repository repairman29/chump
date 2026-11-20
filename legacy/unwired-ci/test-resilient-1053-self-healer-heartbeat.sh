#!/usr/bin/env bash
# test-resilient-1053-self-healer-heartbeat.sh — RESILIENT-1053 (originally scoped as RESILIENT-1052, re-filed to avoid a duplicate-PR collision with #4515)
#
# Verifies fleet-doctor-strict.sh's check_self_healer_heartbeat:
#   1. No ambient.jsonl at all → skip.
#   2. Neither organ_watchdog_tick nor organ_reconcile_applied/noop ever
#      seen → skip (not the primary node / fresh checkout, not a false alarm).
#   3. Both healers ticked recently → pass.
#   4. organ-watchdog ticked recently but organ-reconcile NEVER ticked →
#      fail, detail calls out reconcile as "dead and unowned", and a
#      kind=self_healer_heartbeat_stale paging event lands in ambient.jsonl.
#   5. Both healers ticked once, long ago (past threshold) → fail, detail
#      names both as stale.
#
# Proves the RESILIENT-1053 (originally scoped as RESILIENT-1052, re-filed to avoid a duplicate-PR collision with #4515) behavior: the self-healers (organ-watchdog /
# organ-reconcile) going dark is a paged, observable condition instead of a
# meta-failure nobody notices — chump-organ-reconcile.timer is deliberately
# excluded from organ-manifest.txt (see the NOTE in that file), so the
# existing organ-roll-call-live check (INFRA-3646) cannot catch it; this is
# the independent heartbeat that does.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOCTOR" ]] || fail "fleet-doctor-strict.sh missing"
command -v python3 >/dev/null 2>&1 || fail "python3 required for this test"

TMP="$(mktemp -d -t test-resilient-1052-heartbeat-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT_LOG="$TMP/ambient.jsonl"

# Source the doctor script for direct function access (matches the
# FLEET_DOCTOR_SOURCED pattern used by the other fleet-doctor-strict.sh
# check tests, e.g. test-fleet-doctor-organ-roll-call-live.sh).
export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"

run_check() {
    CHECKS=(); STATUSES=(); DETAILS=(); REMEDIES=(); PASS_COUNT=0; FAIL_COUNT=0
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    SELF_HEALER_WATCHDOG_STALE_S=1200 \
    SELF_HEALER_RECONCILE_STALE_S=1200 \
        check_self_healer_heartbeat
}

now_ts() { date -u +%s; }
iso_at() { # $1 = epoch seconds
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# ── 1. No ambient.jsonl at all → skip ────────────────────────────────────────
rm -f "$AMBIENT_LOG"
run_check
[[ "${#CHECKS[@]}" -eq 1 ]] || fail "expected 1 check registered, got ${#CHECKS[@]}"
if [[ "${STATUSES[0]}" == "skip" ]]; then
    pass "no ambient.jsonl → skip"
else
    fail "expected skip when ambient.jsonl absent, got ${STATUSES[0]}: ${DETAILS[0]}"
fi

# ── 2. ambient.jsonl exists but neither healer has ever ticked → skip ───────
cat > "$AMBIENT_LOG" <<EOF
{"ts":"$(iso_at "$(now_ts)")","kind":"unrelated_event","source":"noise"}
EOF
run_check
if [[ "${STATUSES[0]}" == "skip" ]]; then
    pass "neither healer ever ticked → skip (not a false alarm on non-primary node)"
else
    fail "expected skip when neither healer has ticked, got ${STATUSES[0]}: ${DETAILS[0]}"
fi

# ── 3. both healers ticked recently → pass ───────────────────────────────────
NOW="$(now_ts)"
cat > "$AMBIENT_LOG" <<EOF
{"ts":"$(iso_at $(( NOW - 60 )))","kind":"organ_watchdog_tick","healed":0,"dry_run":0}
{"ts":"$(iso_at $(( NOW - 90 )))","kind":"organ_reconcile_noop"}
EOF
run_check
if [[ "${STATUSES[0]}" == "pass" ]]; then
    pass "both healers ticked recently → pass"
else
    fail "expected pass when both healers ticked recently, got ${STATUSES[0]}: ${DETAILS[0]}"
fi

# ── 4. watchdog ticked recently, reconcile has NEVER ticked → fail + page ───
cat > "$AMBIENT_LOG" <<EOF
{"ts":"$(iso_at $(( NOW - 60 )))","kind":"organ_watchdog_tick","healed":0,"dry_run":0}
EOF
run_check
if [[ "${STATUSES[0]}" == "fail" && "${DETAILS[0]}" == *"reconcile"*"NEVER ticked"* ]]; then
    pass "reconcile never-ticked-while-watchdog-has → fail, detail names reconcile"
else
    fail "expected fail naming reconcile as never-ticked, got ${STATUSES[0]}: ${DETAILS[0]}"
fi
if grep -q '"kind":"self_healer_heartbeat_stale"' "$AMBIENT_LOG"; then
    pass "paging event kind=self_healer_heartbeat_stale landed in ambient.jsonl"
else
    fail "expected kind=self_healer_heartbeat_stale to be emitted on failure — the whole point is that this stops being silent"
fi

# ── 5. both healers ticked once, long ago → fail, both named stale ─────────
cat > "$AMBIENT_LOG" <<EOF
{"ts":"$(iso_at $(( NOW - 7200 )))","kind":"organ_watchdog_tick","healed":0,"dry_run":0}
{"ts":"$(iso_at $(( NOW - 7200 )))","kind":"organ_reconcile_applied","changed":[]}
EOF
run_check
if [[ "${STATUSES[0]}" == "fail" && "${DETAILS[0]}" == *"watchdog"*"silent"* && "${DETAILS[0]}" == *"reconcile"*"silent"* ]]; then
    pass "both stale past threshold → fail, both named"
else
    fail "expected fail naming both watchdog and reconcile as silent, got ${STATUSES[0]}: ${DETAILS[0]}"
fi

echo
echo "All test-resilient-1053-self-healer-heartbeat.sh checks passed."
