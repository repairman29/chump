#!/usr/bin/env bash
# scripts/ci/test-invariant-guard.sh — RESILIENT-1104 / RESILIENT-1105
#
# Depth: EDGE (hermetic). Exercises THE RATCHET's real evaluate/emit/page logic
# against a scratch registry + override-driven probes (no live gh, no Discord),
# so CI proves the exact behavior the fleet needs:
#   - a metric AT/above its floor reads OK and does NOT page
#   - a metric BELOW its page-severity floor is flagged, emits invariant_violation,
#     WOULD PAGE (page sink), and makes the guard exit non-zero  ← the whole point:
#     autonomous ship rate 12.5% -> 0% MUST page next time
#   - a warn-severity floor breach emits a violation but does NOT page and does
#     NOT fail the guard
#   - an "NA" probe SKIPs (never pages) — offline/not-yet-measurable is not an alarm
#   - every pass emits a per-invariant reading + a guard heartbeat tick
#   - --dry-run detects + records to the sink but never actually DMs
#   - fleet-doctor's check_invariant_registry folds a page-violation into a FAIL
# GAPS (not covered here; covered by the live demo in the PR): a real Discord DM,
# the real autonomous-ship-rate gh path, real systemd timer scheduling.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/ops/invariant-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"
PAGES="$TMP/pages.tsv"
REG="$TMP/registry.txt"

# A hermetic registry: one page floor + one warn floor, both driven by the
# ship-rate probe's override hook so we control the measured value exactly.
# (The warn row reuses the same probe deliberately — we only care about the
# severity routing, not the metric identity.)
cat > "$REG" <<EOF
# id | check | comparator | threshold | owner | severity
ship_rate_page | scripts/ops/invariant-checks/zero-touch-ship-rate.sh | ge | 12.5 | RESILIENT | page
ship_rate_warn | scripts/ops/invariant-checks/zero-touch-ship-rate.sh | ge | 12.5 | EFFECTIVE | warn
hours_stub     | scripts/ops/invariant-checks/hours-unattended.sh     | ge | 6    | RESILIENT | page
EOF

FAILS=0
ok(){ echo "  ok: $1"; }
bad(){ echo "  FAIL: $1"; FAILS=$((FAILS+1)); }
has(){ grep -q "$1" "$2" 2>/dev/null; }

run_guard() {  # <ship_rate_value> [extra flags...]  → sets GUARD_RC
    local rate="$1"; shift || true
    : > "$AMBIENT"; : > "$PAGES"
    CHUMP_INVARIANT_REGISTRY="$REG" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    CHUMP_INVARIANT_PAGE_SINK="$PAGES" \
    CHUMP_INVARIANT_SHIP_RATE_OVERRIDE="$rate" \
    CHUMP_INVARIANT_HOURS_UNATTENDED_OVERRIDE="NA" \
        bash "$GUARD" --json "$@" > "$TMP/snap.json" 2>"$TMP/err.log"
    GUARD_RC=$?
}

echo "== case 1: metric ABOVE floor → OK, no page, exit 0 =="
run_guard "42.9"
[ "$GUARD_RC" -eq 0 ] && ok "guard exit 0 when healthy" || bad "guard exit $GUARD_RC when healthy"
has '"kind":"invariant_reading".*"id":"ship_rate_page".*"status":"ok"' "$AMBIENT" && ok "emitted OK reading" || bad "no OK reading"
[ ! -s "$PAGES" ] && ok "no page when healthy" || bad "paged while healthy"
has '"kind":"invariant_guard_tick"' "$AMBIENT" && ok "emitted heartbeat tick" || bad "no heartbeat tick"
has '"kind":"invariant_violation"' "$AMBIENT" && bad "false violation when healthy" || ok "no violation when healthy"

echo "== case 2: REGRESSION — ship rate 12.5% → 0.0% (below page floor) MUST page + fail =="
run_guard "0.0"
[ "$GUARD_RC" -ne 0 ] && ok "guard exits non-zero on page-violation (rc=$GUARD_RC)" || bad "guard exit 0 despite page-violation"
has '"kind":"invariant_violation".*"id":"ship_rate_page".*"severity":"page"' "$AMBIENT" && ok "emitted page-severity violation" || bad "no page violation event"
has "ship_rate_page" "$PAGES" && ok "WOULD-PAGE recorded in page sink (autonomy 12.5%→0% reaches the phone)" || bad "did not record page"
has "measured 0.0" "$PAGES" && ok "page names the measured value + floor" || bad "page missing measured value"
# the warn row breaches too, but must NOT page and must NOT be the reason for exit
has '"kind":"invariant_violation".*"id":"ship_rate_warn".*"severity":"warn"' "$AMBIENT" && ok "warn row emitted a violation" || bad "warn row did not emit violation"
grep -q "ship_rate_warn" "$PAGES" && bad "warn row wrongly paged" || ok "warn row did NOT page"

echo "== case 3: warn-only breach does not fail the guard =="
# a registry of ONLY the warn row, breached → violation emitted, but exit 0.
cat > "$TMP/warnonly.txt" <<EOF
ship_rate_warn | scripts/ops/invariant-checks/zero-touch-ship-rate.sh | ge | 12.5 | EFFECTIVE | warn
EOF
: > "$AMBIENT"; : > "$PAGES"
CHUMP_INVARIANT_REGISTRY="$TMP/warnonly.txt" CHUMP_AMBIENT_LOG="$AMBIENT" \
CHUMP_INVARIANT_PAGE_SINK="$PAGES" CHUMP_INVARIANT_SHIP_RATE_OVERRIDE="1.0" \
    bash "$GUARD" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "warn-only breach exits 0 (no hard gate)" || bad "warn-only breach failed guard (rc=$rc)"
has '"kind":"invariant_violation"' "$AMBIENT" && ok "warn breach still emitted a violation event" || bad "warn breach silent"
[ ! -s "$PAGES" ] && ok "warn breach did not page" || bad "warn breach paged"

echo "== case 4: NA probe SKIPs (offline/not-measurable is not an alarm) =="
run_guard "NA"
has '"kind":"invariant_reading".*"id":"ship_rate_page".*"status":"skip"' "$AMBIENT" && ok "NA → skip reading" || bad "NA not skipped"
[ ! -s "$PAGES" ] && ok "NA did not page" || bad "NA paged"
[ "$GUARD_RC" -eq 0 ] && ok "NA-only pass exits 0" || bad "NA pass exit $GUARD_RC"

echo "== case 5: --dry-run records would-page but the DM path is suppressed =="
# The page sink is a pre-DM receipt; --dry-run still records it (so a gate/audit
# can see the would-page) but the 'DRY-RUN: would page but did not' log proves
# the notify_operator DM was skipped.
run_guard "0.0" --dry-run
has "ship_rate_page" "$PAGES" && ok "dry-run still records the would-page receipt" || bad "dry-run lost the receipt"
grep -q "DRY-RUN: would page but did not" "$TMP/err.log" && ok "dry-run suppressed the actual DM" || bad "dry-run did not suppress DM"

echo "== case 6: fleet-doctor check_invariant_registry folds a regression into a FAIL =="
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"
if [ -f "$DOCTOR" ]; then
    # Source the doctor (FLEET_DOCTOR_SOURCED=1 stops before the full sweep) and
    # call just the one check against a below-floor registry.
    out="$(
      FLEET_DOCTOR_SOURCED=1 \
      CHUMP_FLEET_DOCTOR_REPO_ROOT="$REPO_ROOT" \
      CHUMP_INVARIANT_REGISTRY="$REG" \
      CHUMP_INVARIANT_SHIP_RATE_OVERRIDE="0.0" \
      CHUMP_INVARIANT_HOURS_UNATTENDED_OVERRIDE="NA" \
      CHUMP_AMBIENT_LOG="$AMBIENT" \
      bash -c 'd="$1"; set --; source "$d"; check_invariant_registry; printf "%s|%s\n" "${STATUSES[0]}" "${DETAILS[0]}"' _ "$DOCTOR" 2>/dev/null
    )"
    echo "$out" | grep -q '^fail|' && ok "fleet-doctor registers a FAIL on regression" || bad "fleet-doctor did not FAIL (got: $out)"
    echo "$out" | grep -q 'ship_rate_page' && ok "fleet-doctor names the violated invariant" || bad "fleet-doctor did not name the invariant"
else
    ok "fleet-doctor-strict.sh absent — skipping fold-in assertion"
fi

echo ""
if [ "$FAILS" -eq 0 ]; then echo "PASS: all invariant-guard assertions"; exit 0
else echo "FAIL: $FAILS assertion(s) failed"; exit 1; fi
