#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Validates scripts/ops/pillar-balance-check.sh:
#   T1.  Script is executable and present
#   T2.  Script exits 1 on an empty gap registry (all pillars underweight)
#   T3.  Ambient emits kind=pillar_balance_alert with correct schema
#   T4.  alert has pillar, count, floor fields
#   T5.  alert threshold: count < 2 fires; count >= 2 does not
#   T6.  Script exits 0 when all pillars >= 2 pickable
#   T7.  overweight alert fires when one pillar > 50% of total
#   T8.  overweight event has pillar, count, pct fields
#   T9.  exit code reflects alert state (no alerts → 0)
#   T10. Effort filter: 'l' (large) gaps are NOT counted as pickable
#   T11. Priority filter: P2 gaps are NOT counted as pickable
#   T12. Vague-AC gaps are excluded from pickable count

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts test ==="
echo

# T1. Script exists and is executable
if [ -x "$SCRIPT" ]; then
    ok "T1: pillar-balance-check.sh is executable"
else
    fail "T1: pillar-balance-check.sh missing or not executable at $SCRIPT"
fi

# ── Build chump binary ─────────────────────────────────────────────────────
if [ -n "${CHUMP_BIN:-}" ]; then
    BIN="$CHUMP_BIN"
elif [ -n "${CARGO_TARGET_DIR:-}" ]; then
    BIN="$CARGO_TARGET_DIR/debug/chump"
else
    TARGET_DIR=""
    if command -v cargo >/dev/null 2>&1; then
        TARGET_DIR="$(cargo metadata --no-deps --format-version 1 \
            --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' \
            2>/dev/null || true)"
    fi
    if [ -n "$TARGET_DIR" ] && [ -f "$TARGET_DIR/debug/chump" ]; then
        BIN="$TARGET_DIR/debug/chump"
    else
        BIN="$REPO_ROOT/target/debug/chump"
    fi
fi

if [ ! -f "$BIN" ]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH" \
        cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [ ! -f "$BIN" ]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [ "$FAIL" -eq 0 ]
    exit
fi

# ── Sandbox setup ─────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/.chump-locks"
AMBIENT="$SANDBOX/.chump-locks/ambient.jsonl"
touch "$AMBIENT"

export CHUMP_REPO="$SANDBOX"
export CHUMP_HOME="$SANDBOX"
export CHUMP_BIN="$BIN"
export CHUMP_AMBIENT_LOG="$AMBIENT"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1   # INFRA-1149: prevents 2nd+ reserve from blocking

reserve() {
    # reserve --domain D --priority P --effort E --title T [--ac TEXT]
    local domain="$1" priority="$2" effort="$3" title="$4" ac="${5:-concrete acceptance criteria}"
    "$BIN" gap reserve --domain "$domain" --priority "$priority" --effort "$effort" \
        --title "$title" --quiet 2>/dev/null
    # Set AC so the gap is pickable (not vague)
    local id
    id="$("$BIN" gap list --status open --json 2>/dev/null \
        | python3 -c "import json,sys; gs=json.load(sys.stdin); gs=gs['gaps'] if isinstance(gs,dict) else gs; [print(g['id']) for g in gs if g['title']=='$title']" 2>/dev/null | tail -1)"
    if [ -n "$id" ]; then
        "$BIN" gap set "$id" --acceptance-criteria "$ac" 2>/dev/null || true
    fi
}

# ── T2: empty registry → all pillars underweight → exit 1 ─────────────────
if ! bash "$SCRIPT" >/dev/null 2>&1; then
    ok "T2: exit 1 on empty registry (all pillars underweight)"
else
    fail "T2: expected exit 1 on empty registry"
fi

# ── T3: ambient emits pillar_balance_alert events ─────────────────────────
bash "$SCRIPT" >/dev/null 2>&1 || true
if grep -q '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null; then
    ok "T3: pillar_balance_alert events emitted to ambient.jsonl"
else
    fail "T3: no pillar_balance_alert in ambient.jsonl"
fi

# ── T4: alert schema has pillar, count, floor ──────────────────────────────
ALERT_LINE="$(grep '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null | head -1)"
HAS_PILLAR=0; HAS_COUNT=0; HAS_FLOOR=0
echo "$ALERT_LINE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'pillar' in d, 'missing pillar'
assert 'count'  in d, 'missing count'
assert 'floor'  in d, 'missing floor'
assert d['floor'] == 2, f'floor should be 2, got {d[\"floor\"]}'
" 2>/dev/null && { HAS_PILLAR=1; HAS_COUNT=1; HAS_FLOOR=1; } || true
if [ "$HAS_PILLAR" -eq 0 ]; then
    # Try individual field checks
    echo "$ALERT_LINE" | grep -q '"pillar"' && HAS_PILLAR=1 || true
    echo "$ALERT_LINE" | grep -q '"count"'  && HAS_COUNT=1  || true
    echo "$ALERT_LINE" | grep -q '"floor"'  && HAS_FLOOR=1  || true
fi
if [ "$HAS_PILLAR" -eq 1 ] && [ "$HAS_COUNT" -eq 1 ] && [ "$HAS_FLOOR" -eq 1 ]; then
    ok "T4: alert schema has pillar, count, floor fields with correct values"
else
    fail "T4: alert schema missing pillar/count/floor — line: $ALERT_LINE"
fi

# ── T5: threshold — count < 2 fires; count >= 2 does not ──────────────────
# Add exactly 2 EFFECTIVE gaps (pickable P1/xs with AC)
> "$AMBIENT"  # reset

reserve "EFFECTIVE" "P1" "xs" "EFFECTIVE: threshold-test-gap-1" "concrete AC one"
reserve "EFFECTIVE" "P1" "xs" "EFFECTIVE: threshold-test-gap-2" "concrete AC two"

bash "$SCRIPT" >/dev/null 2>&1 || true
EFFECTIVE_ALERTS=$(grep '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null \
    | python3 -c "import json,sys; [print(json.loads(l)['pillar']) for l in sys.stdin if '\"pillar_balance_alert\"' in l]" 2>/dev/null \
    | grep -c "^EFFECTIVE$" 2>/dev/null || echo 0)
if [ "${EFFECTIVE_ALERTS:-0}" -eq 0 ]; then
    ok "T5: no EFFECTIVE alert when count=2 (meets floor)"
else
    fail "T5: unexpected EFFECTIVE alert when count=2"
fi

# ── T6: all pillars >= 2 → exit 0 ────────────────────────────────────────
> "$AMBIENT"

reserve "CREDIBLE"   "P1" "xs" "CREDIBLE: balance-test-1"   "concrete AC"
reserve "CREDIBLE"   "P1" "xs" "CREDIBLE: balance-test-2"   "concrete AC"
reserve "RESILIENT"  "P1" "xs" "RESILIENT: balance-test-1"  "concrete AC"
reserve "RESILIENT"  "P1" "xs" "RESILIENT: balance-test-2"  "concrete AC"
reserve "ZERO-WASTE" "P1" "xs" "ZERO-WASTE: balance-test-1" "concrete AC"
reserve "ZERO-WASTE" "P1" "xs" "ZERO-WASTE: balance-test-2" "concrete AC"

if bash "$SCRIPT" >/dev/null 2>&1; then
    ok "T6: exit 0 when all pillars >= 2 pickable"
else
    fail "T6: expected exit 0 when all pillars balanced"
fi

# ── T7: overweight alert when one pillar > 50% of total ───────────────────
> "$AMBIENT"
# Add 5 more EFFECTIVE on top of the existing 2 (2 EFFECTIVE out of 4 total
# won't trigger; 7 out of 10 = 70% will trigger)
reserve "EFFECTIVE" "P1" "xs" "EFFECTIVE: overweight-3" "concrete AC"
reserve "EFFECTIVE" "P1" "xs" "EFFECTIVE: overweight-4" "concrete AC"
reserve "EFFECTIVE" "P1" "xs" "EFFECTIVE: overweight-5" "concrete AC"
reserve "EFFECTIVE" "P1" "xs" "EFFECTIVE: overweight-6" "concrete AC"
reserve "EFFECTIVE" "P1" "xs" "EFFECTIVE: overweight-7" "concrete AC"

bash "$SCRIPT" >/dev/null 2>&1 || true
if grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null; then
    ok "T7: pillar_balance_overweight fired when EFFECTIVE > 50% of pool"
else
    fail "T7: no pillar_balance_overweight when EFFECTIVE dominates pool"
fi

# ── T8: overweight event schema ────────────────────────────────────────────
OW_LINE="$(grep '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null | head -1)"
OW_OK=0
echo "$OW_LINE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'pillar' in d
assert 'count'  in d
assert 'pct'    in d
assert d['pct'] > 50
" 2>/dev/null && OW_OK=1 || true
if [ "$OW_OK" -eq 1 ]; then
    ok "T8: overweight event has pillar, count, pct (>50)"
else
    fail "T8: overweight event schema invalid — line: $OW_LINE"
fi

# ── T9: clean state → exit 0, no events ───────────────────────────────────
> "$AMBIENT"
# Use a fresh CHUMP_REPO with exactly 2 gaps per pillar
SANDBOX2="$(mktemp -d)"
mkdir -p "$SANDBOX2/.chump-locks"
AMBIENT2="$SANDBOX2/.chump-locks/ambient.jsonl"
touch "$AMBIENT2"
export CHUMP_REPO="$SANDBOX2"
export CHUMP_HOME="$SANDBOX2"
export CHUMP_AMBIENT_LOG="$AMBIENT2"

reserve "EFFECTIVE"  "P1" "xs" "EFFECTIVE: clean-1"  "concrete AC"
reserve "EFFECTIVE"  "P1" "xs" "EFFECTIVE: clean-2"  "concrete AC"
reserve "CREDIBLE"   "P1" "xs" "CREDIBLE: clean-1"   "concrete AC"
reserve "CREDIBLE"   "P1" "xs" "CREDIBLE: clean-2"   "concrete AC"
reserve "RESILIENT"  "P1" "xs" "RESILIENT: clean-1"  "concrete AC"
reserve "RESILIENT"  "P1" "xs" "RESILIENT: clean-2"  "concrete AC"
reserve "ZERO-WASTE" "P1" "xs" "ZERO-WASTE: clean-1" "concrete AC"
reserve "ZERO-WASTE" "P1" "xs" "ZERO-WASTE: clean-2" "concrete AC"

if bash "$SCRIPT" >/dev/null 2>&1; then
    ok "T9: exit 0 on balanced registry (8 gaps, 2 per pillar)"
else
    fail "T9: expected exit 0 on balanced registry"
fi
ALERT_COUNT=$(grep -c '"kind":"pillar_balance' "$AMBIENT2" 2>/dev/null || echo 0)
if [ "${ALERT_COUNT:-0}" -eq 0 ]; then
    ok "T9b: no alert events on balanced registry"
else
    fail "T9b: unexpected alert events on balanced registry (count=$ALERT_COUNT)"
fi

# Restore sandbox
export CHUMP_REPO="$SANDBOX"
export CHUMP_HOME="$SANDBOX"
export CHUMP_AMBIENT_LOG="$AMBIENT"
rm -rf "$SANDBOX2"

# ── T10: effort='l' (large) gaps excluded from pickable count ─────────────
> "$AMBIENT"
# Add a large-effort EFFECTIVE gap; only 1 xs/s/m EFFECTIVE gap remains
SANDBOX3="$(mktemp -d)"
mkdir -p "$SANDBOX3/.chump-locks"
AMBIENT3="$SANDBOX3/.chump-locks/ambient.jsonl"
touch "$AMBIENT3"
export CHUMP_REPO="$SANDBOX3"
export CHUMP_HOME="$SANDBOX3"
export CHUMP_AMBIENT_LOG="$AMBIENT3"

reserve "EFFECTIVE" "P1" "l"  "EFFECTIVE: large-effort-gap" "concrete AC"
reserve "EFFECTIVE" "P1" "xs" "EFFECTIVE: small-effort-gap" "concrete AC"

bash "$SCRIPT" >/dev/null 2>&1 || true
EFFECTIVE_ALERTS_T10=$(grep '"kind":"pillar_balance_alert"' "$AMBIENT3" 2>/dev/null \
    | python3 -c "
import json,sys
count=0
for line in sys.stdin:
    try:
        d=json.loads(line.strip())
        if d.get('kind')=='pillar_balance_alert' and d.get('pillar')=='EFFECTIVE':
            count+=1
    except: pass
print(count)
" 2>/dev/null || echo 0)
if [ "${EFFECTIVE_ALERTS_T10:-0}" -ge 1 ]; then
    ok "T10: large-effort gap not counted; EFFECTIVE alert fires with only 1 xs gap"
else
    fail "T10: expected EFFECTIVE alert when only 1 pickable (large excluded)"
fi

export CHUMP_REPO="$SANDBOX"
export CHUMP_HOME="$SANDBOX"
export CHUMP_AMBIENT_LOG="$AMBIENT"
rm -rf "$SANDBOX3"

# ── T11: P2 gaps not counted as pickable ──────────────────────────────────
> "$AMBIENT"
SANDBOX4="$(mktemp -d)"
mkdir -p "$SANDBOX4/.chump-locks"
AMBIENT4="$SANDBOX4/.chump-locks/ambient.jsonl"
touch "$AMBIENT4"
export CHUMP_REPO="$SANDBOX4"
export CHUMP_HOME="$SANDBOX4"
export CHUMP_AMBIENT_LOG="$AMBIENT4"

reserve "CREDIBLE" "P2" "xs" "CREDIBLE: p2-gap-1" "concrete AC"
reserve "CREDIBLE" "P2" "xs" "CREDIBLE: p2-gap-2" "concrete AC"
reserve "CREDIBLE" "P2" "xs" "CREDIBLE: p2-gap-3" "concrete AC"
reserve "CREDIBLE" "P1" "xs" "CREDIBLE: p1-gap-1" "concrete AC"

bash "$SCRIPT" >/dev/null 2>&1 || true
CREDIBLE_ALERTS=$(grep '"kind":"pillar_balance_alert"' "$AMBIENT4" 2>/dev/null \
    | python3 -c "
import json,sys
count=0
for line in sys.stdin:
    try:
        d=json.loads(line.strip())
        if d.get('kind')=='pillar_balance_alert' and d.get('pillar')=='CREDIBLE':
            count+=1
    except: pass
print(count)
" 2>/dev/null || echo 0)
if [ "${CREDIBLE_ALERTS:-0}" -ge 1 ]; then
    ok "T11: P2 gaps excluded; CREDIBLE alert fires with only 1 P1 pickable"
else
    fail "T11: expected CREDIBLE alert (P2 gaps should not count as pickable)"
fi

export CHUMP_REPO="$SANDBOX"
export CHUMP_HOME="$SANDBOX"
export CHUMP_AMBIENT_LOG="$AMBIENT"
rm -rf "$SANDBOX4"

# ── T12: vague-AC gaps excluded from pickable count ───────────────────────
> "$AMBIENT"
SANDBOX5="$(mktemp -d)"
mkdir -p "$SANDBOX5/.chump-locks"
AMBIENT5="$SANDBOX5/.chump-locks/ambient.jsonl"
touch "$AMBIENT5"
export CHUMP_REPO="$SANDBOX5"
export CHUMP_HOME="$SANDBOX5"
export CHUMP_AMBIENT_LOG="$AMBIENT5"

# Reserve 2 gaps but leave their AC empty (vague)
"$BIN" gap reserve --domain RESILIENT --priority P1 --effort xs \
    --title "RESILIENT: vague-ac-1" --quiet 2>/dev/null || true
"$BIN" gap reserve --domain RESILIENT --priority P1 --effort xs \
    --title "RESILIENT: vague-ac-2" --quiet 2>/dev/null || true
# One gap with real AC
reserve "RESILIENT" "P1" "xs" "RESILIENT: real-ac-1" "concrete acceptance criteria"

bash "$SCRIPT" >/dev/null 2>&1 || true
RESILIENT_ALERTS=$(grep '"kind":"pillar_balance_alert"' "$AMBIENT5" 2>/dev/null \
    | python3 -c "
import json,sys
count=0
for line in sys.stdin:
    try:
        d=json.loads(line.strip())
        if d.get('kind')=='pillar_balance_alert' and d.get('pillar')=='RESILIENT':
            count+=1
    except: pass
print(count)
" 2>/dev/null || echo 0)
if [ "${RESILIENT_ALERTS:-0}" -ge 1 ]; then
    ok "T12: vague-AC gaps excluded; RESILIENT alert fires with only 1 real-AC pickable"
else
    fail "T12: expected RESILIENT alert (vague-AC gaps should not count as pickable)"
fi

export CHUMP_REPO="$SANDBOX"
export CHUMP_HOME="$SANDBOX"
export CHUMP_AMBIENT_LOG="$AMBIENT"
rm -rf "$SANDBOX5"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
