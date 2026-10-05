#!/usr/bin/env bash
# test-cost-cap-watch.sh — RESILIENT-415
#
# Governance: no organ may halt/park the fleet without a TESTED
# auto-recovery path + a loud page (same precedent as RESILIENT-326's
# disk-reactor halt-recovery test). scripts/coord/cost-cap-watch.sh parks
# the fleet (AUTONOMY_LEVEL=0) on a cap-exhaustion signal and must resume
# it once the cap-reset probe succeeds — this proves both halves, using
# the script's test hooks (CHUMP_AUTON_FILE, CHUMP_AMBIENT_LOG,
# CHUMP_COST_CAP_PARK_FILE, CHUMP_FAKE_COST_CAP_PROBE) so nothing real is
# touched.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WATCH="$REPO_ROOT/scripts/coord/cost-cap-watch.sh"
[[ -f "$WATCH" ]] || { echo "FAIL: $WATCH not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/scripts/dispatch" "$FAKE_REPO/.chump-locks"
RECALL_LOG="$TMP/recall-calls.log"
cat > "$FAKE_REPO/scripts/dispatch/operator-recall.sh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$RECALL_LOG"
exit 0
EOF
chmod +x "$FAKE_REPO/scripts/dispatch/operator-recall.sh"

# ── Test 1: no exhaustion signal → --park-check is a no-op ─────────────────
AUTON="$TMP/AUTONOMY_LEVEL"
AMBIENT="$TMP/ambient-1.jsonl"
PARK_FILE="$TMP/parked-1.json"
echo 5 > "$AUTON"
: > "$AMBIENT"

CHUMP_REPO="$FAKE_REPO" CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_AUTON_FILE="$AUTON" \
CHUMP_COST_CAP_PARK_FILE="$PARK_FILE" \
    bash "$WATCH" --park-check
rc=$?
[[ "$rc" != "0" ]] && ok "no signal: --park-check is a no-op (exit $rc)" \
    || bad "no signal: --park-check unexpectedly parked"
[[ -f "$PARK_FILE" ]] && bad "no signal: park file should not exist" \
    || ok "no signal: park file absent"
[[ "$(cat "$AUTON")" == "5" ]] && ok "no signal: AUTONOMY_LEVEL untouched" \
    || bad "no signal: AUTONOMY_LEVEL mutated without a signal"

# ── Test 2: fleet_backend_no_live_floor signal → park halts + pages ────────
AUTON="$TMP/AUTONOMY_LEVEL2"
AMBIENT="$TMP/ambient-2.jsonl"
PARK_FILE="$TMP/parked-2.json"
echo 5 > "$AUTON"
echo '{"ts":"2026-10-01T00:00:00Z","kind":"fleet_backend_no_live_floor","fail_class":"rate-limit"}' > "$AMBIENT"
: > "$RECALL_LOG"

CHUMP_REPO="$FAKE_REPO" CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_AUTON_FILE="$AUTON" \
CHUMP_COST_CAP_PARK_FILE="$PARK_FILE" \
    bash "$WATCH" --park-check
rc=$?
[[ "$rc" == "0" ]] && ok "exhaustion signal: --park-check parks (exit 0)" \
    || bad "exhaustion signal: expected exit 0, got $rc"
[[ "$(cat "$AUTON" 2>/dev/null)" == "0" ]] && ok "exhaustion signal: AUTONOMY_LEVEL set to 0" \
    || bad "exhaustion signal: AUTONOMY_LEVEL not halted — found '$(cat "$AUTON" 2>/dev/null)'"
[[ -f "$PARK_FILE" ]] && ok "exhaustion signal: park-state file written" \
    || bad "exhaustion signal: park-state file missing"
grep -q '"kind":"cost_cap_watch_parked"' "$AMBIENT" 2>/dev/null \
    && ok "exhaustion signal: cost_cap_watch_parked event emitted" \
    || bad "exhaustion signal: cost_cap_watch_parked event missing"
grep -q 'COST_CAP' "$RECALL_LOG" 2>/dev/null \
    && ok "exhaustion signal: operator-recall paged with COST_CAP" \
    || bad "exhaustion signal: operator was not paged (silent halt regression)"

# ── Test 3: parked + probe still dead → --resume-check stays parked ───────
CHUMP_REPO="$FAKE_REPO" CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_AUTON_FILE="$AUTON" \
CHUMP_COST_CAP_PARK_FILE="$PARK_FILE" CHUMP_FAKE_COST_CAP_PROBE=dead \
    bash "$WATCH" --resume-check
rc=$?
[[ "$rc" != "0" ]] && ok "probe dead: --resume-check stays parked (exit $rc)" \
    || bad "probe dead: --resume-check unexpectedly resumed"
[[ "$(cat "$AUTON")" == "0" ]] && ok "probe dead: AUTONOMY_LEVEL still halted" \
    || bad "probe dead: AUTONOMY_LEVEL was restored despite a dead probe"
[[ -f "$PARK_FILE" ]] && ok "probe dead: park-state file still present" \
    || bad "probe dead: park-state file was removed prematurely"

# ── Test 4: parked + probe live → --resume-check restores + unparks ───────
CHUMP_REPO="$FAKE_REPO" CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_AUTON_FILE="$AUTON" \
CHUMP_COST_CAP_PARK_FILE="$PARK_FILE" CHUMP_FAKE_COST_CAP_PROBE=live \
    bash "$WATCH" --resume-check
rc=$?
[[ "$rc" == "0" ]] && ok "probe live: --resume-check resumes (exit 0)" \
    || bad "probe live: expected exit 0, got $rc"
[[ "$(cat "$AUTON")" == "5" ]] && ok "probe live: AUTONOMY_LEVEL restored to prior value (5)" \
    || bad "probe live: AUTONOMY_LEVEL not restored — found '$(cat "$AUTON")' (permanent-halt regression)"
[[ -f "$PARK_FILE" ]] && bad "probe live: park-state file should be removed after resume" \
    || ok "probe live: park-state file cleared"
grep -q '"kind":"cost_cap_watch_resumed"' "$AMBIENT" 2>/dev/null \
    && ok "probe live: cost_cap_watch_resumed event emitted" \
    || bad "probe live: cost_cap_watch_resumed event missing"

# ── Test 5: once resumed, --resume-check on an unparked fleet is a no-op ──
CHUMP_REPO="$FAKE_REPO" CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_AUTON_FILE="$AUTON" \
CHUMP_COST_CAP_PARK_FILE="$PARK_FILE" CHUMP_FAKE_COST_CAP_PROBE=live \
    bash "$WATCH" --resume-check
rc=$?
[[ "$rc" != "0" ]] && ok "already resumed: --resume-check is a no-op (exit $rc)" \
    || bad "already resumed: --resume-check should no-op when not parked"

echo
echo "cost-cap-watch: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
