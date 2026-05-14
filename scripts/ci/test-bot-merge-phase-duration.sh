#!/usr/bin/env bash
# scripts/ci/test-bot-merge-phase-duration.sh — INFRA-1288
#
# Validates that stage_done() in bot-merge.sh emits a
# `kind=bot_merge_phase_duration` event to CHUMP_AMBIENT_LOG with
# all required fields (INFRA-1067).
#
# Tests:
#   1. Event emitted with kind=bot_merge_phase_duration
#   2. Event includes non-empty `phase` field matching __STAGE_LABEL
#   3. Event includes non-negative integer `elapsed_s` field
#   4. Event includes `gap` field derived from GAP_IDS[0]
#   5. Event includes `branch` field
#   6. Event is valid JSON (parseable)
#   7. Force-fire: if emission is removed, test fails

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d -t test-bm-phase-dur.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

BM="$REPO_ROOT/scripts/coord/bot-merge.sh"
[[ -f "$BM" ]] || { echo "SKIP: bot-merge.sh not found at $BM"; exit 0; }

AMBIENT="$TMP/ambient.jsonl"

# ── Build a driver that sources just the stage_done() function and its
#    minimal stubs, then calls it. ──────────────────────────────────────────
cat > "$TMP/driver.sh" <<DRIVER
#!/usr/bin/env bash
set -uo pipefail

# Stub: info() just discards output so the test log is clean.
info() { : ; }

# Stub: _bm_steps_append() is a no-op — not under test here.
_bm_steps_append() { : ; }

# Required globals for stage_done().
__STAGE_LABEL="fetch-pr-state"
__STAGE_T0=\$(( \$(date +%s) - 5 ))   # simulate 5s elapsed
GAP_IDS=("INFRA-TEST-42")
BRANCH="chump/infra-test-42-claim"
REPO_ROOT="$TMP"
export CHUMP_AMBIENT_LOG="$AMBIENT"

# Extract and source just the stage_done() body from bot-merge.sh.
$(awk '/^stage_done\(\)/{p=1} p{print} p && /^}$/{p=0}' "$BM")

# Call the function.
stage_done
DRIVER
chmod +x "$TMP/driver.sh"

# ── Test 1-6: happy-path emission ─────────────────────────────────────────
echo "--- Test 1-6: stage_done() emits bot_merge_phase_duration ---"
bash "$TMP/driver.sh" 2>/dev/null

if [[ -f "$AMBIENT" ]]; then
    ok "Test 1: ambient log file created"
else
    fail "Test 1: ambient log file not created at $AMBIENT"
fi

EVENT=$(grep '"kind":"bot_merge_phase_duration"' "$AMBIENT" 2>/dev/null | tail -1)
if [[ -n "$EVENT" ]]; then
    ok "Test 2: event with kind=bot_merge_phase_duration emitted"
else
    fail "Test 2: no bot_merge_phase_duration event in ambient log"
    echo "=== ambient log contents ==="
    cat "$AMBIENT" 2>/dev/null || echo "(empty)"
    echo "======="
fi

# Field: phase
if echo "$EVENT" | grep -q '"phase":"fetch-pr-state"'; then
    ok "Test 3: phase field matches __STAGE_LABEL"
else
    fail "Test 3: phase field missing or wrong — event: $EVENT"
fi

# Field: elapsed_s (integer ≥ 0)
if echo "$EVENT" | grep -qE '"elapsed_s":[0-9]+'; then
    ok "Test 4: elapsed_s is a non-negative integer"
else
    fail "Test 4: elapsed_s missing or not an integer — event: $EVENT"
fi

# Field: gap
if echo "$EVENT" | grep -q '"gap":"INFRA-TEST-42"'; then
    ok "Test 5: gap field populated from GAP_IDS[0]"
else
    fail "Test 5: gap field missing or wrong — event: $EVENT"
fi

# Field: branch
if echo "$EVENT" | grep -q '"branch":"chump/infra-test-42-claim"'; then
    ok "Test 6: branch field populated"
else
    fail "Test 6: branch field missing or wrong — event: $EVENT"
fi

# Valid JSON (requires python3 or jq)
if command -v python3 &>/dev/null; then
    if echo "$EVENT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        ok "Test 7: event is valid JSON"
    else
        fail "Test 7: event is not valid JSON — $EVENT"
    fi
elif command -v jq &>/dev/null; then
    if echo "$EVENT" | jq . &>/dev/null; then
        ok "Test 7: event is valid JSON"
    else
        fail "Test 7: event is not valid JSON — $EVENT"
    fi
else
    ok "Test 7: SKIP (no python3/jq available)"
fi

# ── Test 8: force-fire — emission absent → test exits non-zero ────────────
echo "--- Test 8: force-fire (emission removed → should fail) ---"
# Rewrite driver without the phase_duration printf line.
sed '/bot_merge_phase_duration/d; /printf.*kind/d; /sd_ts\|sd_amb\|sd_gap/d; /_sd_/d' \
    "$TMP/driver.sh" > "$TMP/driver-stripped.sh"
chmod +x "$TMP/driver-stripped.sh"
AMBIENT_STRIPPED="$TMP/ambient-stripped.jsonl"
sed -i.bak "s|$AMBIENT|$AMBIENT_STRIPPED|g" "$TMP/driver-stripped.sh"
bash "$TMP/driver-stripped.sh" 2>/dev/null || true
if grep -q '"kind":"bot_merge_phase_duration"' "$AMBIENT_STRIPPED" 2>/dev/null; then
    fail "Test 8: force-fire failed — emission found even in stripped driver"
else
    ok "Test 8: force-fire confirmed — no emission without the printf"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
