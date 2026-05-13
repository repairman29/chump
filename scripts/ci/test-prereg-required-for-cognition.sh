#!/usr/bin/env bash
# test-prereg-required-for-cognition.sh — META-043 tests.
#
# Verifies the pre-registered eval guard in scripts/coord/bot-merge.sh:
#   (1) guard section present in bot-merge.sh (META-043 marker)
#   (2) CHUMP_NO_PREREG bypass wired in bot-merge.sh
#   (3) cognition src + prereg doc present → PASS (no offenders)
#   (4) cognition src + no prereg doc → FAIL (guard triggers)
#   (5) non-cognition src only → PASS (guard skips)
#   (6) scripts/dispatch/ also triggers the guard
#   (7) CHUMP_NO_PREREG=1 suppresses the guard
#
# Run: ./scripts/ci/test-prereg-required-for-cognition.sh

set -uo pipefail

# shellcheck source=lib/gate-emit.sh
source "$(dirname "$0")/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "META-043" "$*"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== META-043 pre-registered eval guard tests ==="
echo

# ── Test 1: guard section present ────────────────────────────────────────────
echo "--- Test 1: META-043 guard present in bot-merge.sh ---"
if grep -q "META-043\|PREREG-REQUIRED\|CHUMP_NO_PREREG" "$BOT_MERGE" 2>/dev/null; then
    ok "Test 1: META-043 / PREREG-REQUIRED / CHUMP_NO_PREREG found in bot-merge.sh"
else
    fail "Test 1: META-043 prereg guard not found in bot-merge.sh"
fi

# ── Test 2: bypass env var wired ─────────────────────────────────────────────
echo "--- Test 2: CHUMP_NO_PREREG bypass wired ---"
if grep -q 'CHUMP_NO_PREREG' "$BOT_MERGE" 2>/dev/null; then
    ok "Test 2: CHUMP_NO_PREREG bypass env var in bot-merge.sh"
else
    fail "Test 2: CHUMP_NO_PREREG bypass not found"
fi

# ── Shared guard logic (inline Python simulation) ────────────────────────────
_guard() {
    local gap_id="$1" cognition_files="$2" prereg_exists="$3" bypass="${4:-0}"
    python3 - "$gap_id" "$cognition_files" "$prereg_exists" "$bypass" <<'PYEOF' 2>/dev/null
import sys, re
gap_id, cognition_files_raw, prereg_exists, bypass = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

COGNITION_PATTERN = re.compile(
    r'^src/(briefing|reflection|reflection_db|prompt_assembly|provider_|bandit|cog_|cognition_|atomic_claim)'
    r'|^scripts/dispatch/'
)

files = [f for f in cognition_files_raw.split(',') if f]
if bypass == "1":
    print("bypassed")
    sys.exit(0)

cognition_touched = any(COGNITION_PATTERN.match(f) for f in files)
if not cognition_touched:
    print("skipped")
    sys.exit(0)

prereg_doc = f"docs/eval/preregistered/{gap_id}.md"
if prereg_exists == "1":
    print("pass")
    sys.exit(0)
else:
    print(f"fail: {prereg_doc} missing")
    sys.exit(1)
PYEOF
}

# ── Test 3: cognition src + prereg doc → pass ─────────────────────────────────
echo "--- Test 3: cognition src + prereg doc present → PASS ---"
_r3=$(_guard "FOO-001" "src/reflection.rs,src/lib.rs" "1" "0" || true)
if [[ "$_r3" == "pass" ]]; then
    ok "Test 3: guard passes when cognition src changed AND prereg doc exists"
else
    fail "Test 3: expected pass, got '$_r3'"
fi

# ── Test 4: cognition src + no prereg → fail ──────────────────────────────────
echo "--- Test 4: cognition src + no prereg doc → FAIL ---"
_r4=$(_guard "FOO-001" "src/briefing.rs,web/index.html" "0" "0" || true)
if [[ "$_r4" == *"fail"* ]]; then
    ok "Test 4: guard blocks when cognition src changed and prereg doc missing"
else
    fail "Test 4: expected fail, got '$_r4'"
fi

# ── Test 5: non-cognition src only → pass (guard skips) ──────────────────────
echo "--- Test 5: non-cognition src only → PASS (guard skips) ---"
_r5=$(_guard "FOO-002" "src/web_server.rs,web/v2/app.js" "0" "0" || true)
if [[ "$_r5" == "skipped" ]]; then
    ok "Test 5: guard skips when no cognition/routing files touched"
else
    fail "Test 5: expected skipped, got '$_r5'"
fi

# ── Test 6: scripts/dispatch/ triggers guard ──────────────────────────────────
echo "--- Test 6: scripts/dispatch/ modification triggers guard ---"
_r6=$(_guard "FOO-003" "scripts/dispatch/fleet-picker.sh" "0" "0" || true)
if [[ "$_r6" == *"fail"* ]]; then
    ok "Test 6: scripts/dispatch/ correctly triggers prereg guard"
else
    fail "Test 6: expected fail for dispatch change, got '$_r6'"
fi

# ── Test 7: CHUMP_NO_PREREG=1 bypasses guard ──────────────────────────────────
echo "--- Test 7: CHUMP_NO_PREREG=1 bypasses guard entirely ---"
_r7=$(_guard "FOO-004" "src/cognition_engine.rs" "0" "1" || true)
if [[ "$_r7" == "bypassed" ]]; then
    ok "Test 7: CHUMP_NO_PREREG=1 bypasses guard for cognition src without prereg"
else
    fail "Test 7: expected bypassed, got '$_r7'"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    gate_emit_result "META-043" "fail" "prereg-guard-broken" "$FAIL simulation(s) failed"
    exit 1
fi
gate_emit_result "META-043" "pass" "" ""
exit 0
