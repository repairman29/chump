#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests for scripts/ops/pillar-balance-check.sh:
#   1. Script exists and is executable
#   2. Alert fires + exit non-zero when a pillar has 0 gaps (< floor=2)
#   3. pillar_balance_alert event has correct schema fields
#   4. Exit 0 when all pillars at floor (>= 2 each)
#   5. Overweight alert fires when one pillar > 50% of total
#   6. pillar_balance_overweight event has correct schema fields
#   7. Multiple pillars under floor → multiple pillar_balance_alert events
#   8. --dry-run does not write to ambient.jsonl
#   9. CHUMP_PILLAR_BALANCE_DISABLED=1 bypasses all checks (exit 0)
#  10. Script is Bash 3.2 compatible (no declare -A / mapfile usage)
#
# All tests use CHUMP_BIN (fixture binary) and isolated CHUMP_REPO temp dirs.

set -uo pipefail

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: script exists and is executable ───────────────────────────────────
echo "--- Test 1: script exists and is executable ---"
if [ -x "$SCRIPT" ]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh missing or not executable at: $SCRIPT"
fi

# ── Binary discovery (INFRA-481: honor shared target-dir) ─────────────────────
if [ -z "${CHUMP_BIN:-}" ]; then
    if command -v cargo >/dev/null 2>&1; then
        _tdir=$(cargo metadata --no-deps \
            --manifest-path "$REPO_ROOT/Cargo.toml" \
            --format-version 1 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('target_directory',''))" \
            2>/dev/null || true)
    else
        _tdir=""
    fi
    if [ -x "${_tdir:-}/debug/chump" ]; then
        export CHUMP_BIN="${_tdir}/debug/chump"
    elif [ -x "$REPO_ROOT/target/debug/chump" ]; then
        export CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    else
        echo "  [build] cargo build --bin chump..."
        cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
        if [ -x "${_tdir:-}/debug/chump" ]; then
            export CHUMP_BIN="${_tdir}/debug/chump"
        elif [ -x "$REPO_ROOT/target/debug/chump" ]; then
            export CHUMP_BIN="$REPO_ROOT/target/debug/chump"
        else
            fail "chump binary not found after build — skipping functional tests"
            echo "=== Results: $PASS passed, $FAIL failed ==="
            exit $( [ "$FAIL" -eq 0 ] && echo 0 || echo 1 )
        fi
    fi
fi

# Shared env for all fixture DBs
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1   # INFRA-1149: prevent similarity block
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_BINARY_STALENESS_CHECK=0

_reserve() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}"
    local ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve \
        --domain INFRA \
        --priority "$priority" \
        --effort "$effort" \
        --title "$title" \
        --acceptance-criteria "$ac" \
        --quiet \
        --force \
        --force-duplicate \
        2>/dev/null || true
}

_make_repo() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/.chump" "$dir/docs/gaps" "$dir/.chump-locks"
    # cd into dir so git-rev-parse finds this repo, not the main project root
    (cd "$dir" && git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true)
    git -C "$dir" config user.email "ci@ci.local" 2>/dev/null || true
    git -C "$dir" config user.name "CI" 2>/dev/null || true
    printf '%s' "$dir"
}

# ── Test 2 & 3: alert fires when a pillar has 0 gaps ─────────────────────────
echo
echo "--- Test 2+3: alert fires + schema correct when a pillar has 0 gaps ---"
T=$(mktemp -d)
TMP_DB=$(_make_repo)
AMBIENT_T="$T/ambient.jsonl"

OLD_REPO="${CHUMP_REPO:-}"
export CHUMP_REPO="$TMP_DB"
# Seed only 3 pillars — ZERO-WASTE has 0 gaps
_reserve "EFFECTIVE: fixture-2a" P1 xs "check effective a"
_reserve "EFFECTIVE: fixture-2b" P1 xs "check effective b"
_reserve "CREDIBLE: fixture-2c" P1 xs "check credible c"
_reserve "CREDIBLE: fixture-2d" P1 xs "check credible d"
_reserve "RESILIENT: fixture-2e" P1 xs "check resilient e"
_reserve "RESILIENT: fixture-2f" P1 xs "check resilient f"
# ZERO-WASTE: none — should trigger alert

out2=$(CHUMP_AMBIENT_OVERRIDE="$AMBIENT_T" bash "$SCRIPT" 2>&1 || true)
rc2=$(CHUMP_AMBIENT_OVERRIDE="$AMBIENT_T" bash "$SCRIPT" >/dev/null 2>&1; echo $?) || rc2=1

if echo "$out2" | grep -q "ALERT"; then
    ok "Test 2: ALERT line printed for under-floor pillar"
else
    fail "Test 2: expected ALERT in output — got: $out2"
fi

if [ "${rc2:-1}" -ne 0 ] || ! CHUMP_AMBIENT_OVERRIDE="$AMBIENT_T" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "Test 2: exit non-zero when alert fires"
else
    fail "Test 2: expected non-zero exit when pillar under floor"
fi

# Schema check
if [ -f "$AMBIENT_T" ]; then
    _schema_ok=1
    for _field in '"kind":"pillar_balance_alert"' '"pillar"' '"count"' '"floor"'; do
        if ! grep -q "$_field" "$AMBIENT_T"; then
            _schema_ok=0
            fail "Test 3: pillar_balance_alert missing field: $_field"
        fi
    done
    [ "$_schema_ok" -eq 1 ] && ok "Test 3: pillar_balance_alert event has correct schema (kind, pillar, count, floor)"
else
    fail "Test 3: ambient.jsonl not written — cannot check schema"
fi

rm -rf "$T" "$TMP_DB"
[ -n "$OLD_REPO" ] && export CHUMP_REPO="$OLD_REPO" || unset CHUMP_REPO

# ── Test 4: exit 0 when all pillars >= floor ──────────────────────────────────
echo
echo "--- Test 4: exit 0 when all pillars >= floor=2 ---"
T4=$(mktemp -d)
TMP_DB4=$(_make_repo)
AMBIENT_T4="$T4/ambient.jsonl"

OLD_REPO="${CHUMP_REPO:-}"
export CHUMP_REPO="$TMP_DB4"
for _p in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
    _reserve "$_p: balanced-a" P1 xs "check a"
    _reserve "$_p: balanced-b" P1 xs "check b"
done

if CHUMP_AMBIENT_OVERRIDE="$AMBIENT_T4" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "Test 4: exit 0 when all pillars balanced (>= 2 each)"
else
    fail "Test 4: expected exit 0 for balanced pillars"
fi

if [ -f "$AMBIENT_T4" ]; then
    if grep -q "pillar_balance" "$AMBIENT_T4" 2>/dev/null; then
        fail "Test 4: no alerts should fire when balanced, but ambient has events"
    else
        ok "Test 4: no pillar_balance events emitted when balanced"
    fi
else
    ok "Test 4: no ambient.jsonl written when balanced (no events)"
fi

rm -rf "$T4" "$TMP_DB4"
[ -n "$OLD_REPO" ] && export CHUMP_REPO="$OLD_REPO" || unset CHUMP_REPO

# ── Test 5 & 6: overweight alert fires and schema correct ─────────────────────
echo
echo "--- Test 5+6: overweight alert fires + schema correct ---"
T5=$(mktemp -d)
TMP_DB5=$(_make_repo)
AMBIENT_T5="$T5/ambient.jsonl"

OLD_REPO="${CHUMP_REPO:-}"
export CHUMP_REPO="$TMP_DB5"
# 8 EFFECTIVE + 1 each of others → EFFECTIVE is 8/11 ≈ 73% > 50%
for i in $(seq 1 8); do
    _reserve "EFFECTIVE: ow-$i" P1 xs "check $i"
done
_reserve "CREDIBLE: ow-c" P1 xs "check credible"
_reserve "RESILIENT: ow-r" P1 xs "check resilient"
_reserve "ZERO-WASTE: ow-z" P1 xs "check zero-waste"

out5=$(CHUMP_AMBIENT_OVERRIDE="$AMBIENT_T5" bash "$SCRIPT" 2>&1 || true)

if echo "$out5" | grep -q "overweight\|ALERT"; then
    ok "Test 5: overweight ALERT printed when pillar > 50% of total"
else
    fail "Test 5: expected overweight ALERT — got: $out5"
fi

if [ -f "$AMBIENT_T5" ]; then
    if grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT_T5"; then
        ok "Test 5: pillar_balance_overweight event emitted"
    else
        fail "Test 5: pillar_balance_overweight event not found in ambient.jsonl"
    fi

    _schema5_ok=1
    for _field in '"kind":"pillar_balance_overweight"' '"pillar"' '"count"' '"pct"' '"total"' '"threshold"'; do
        if ! grep -q "$_field" "$AMBIENT_T5"; then
            _schema5_ok=0
            fail "Test 6: pillar_balance_overweight missing field: $_field"
        fi
    done
    [ "$_schema5_ok" -eq 1 ] && ok "Test 6: pillar_balance_overweight event has correct schema"
else
    fail "Test 5+6: ambient.jsonl not written — cannot check overweight schema"
fi

rm -rf "$T5" "$TMP_DB5"
[ -n "$OLD_REPO" ] && export CHUMP_REPO="$OLD_REPO" || unset CHUMP_REPO

# ── Test 7: multiple pillars under floor → multiple alerts ────────────────────
echo
echo "--- Test 7: multiple pillars under floor → multiple pillar_balance_alert events ---"
T7=$(mktemp -d)
TMP_DB7=$(_make_repo)
AMBIENT_T7="$T7/ambient.jsonl"

OLD_REPO="${CHUMP_REPO:-}"
export CHUMP_REPO="$TMP_DB7"
# Only EFFECTIVE has >= 2; CREDIBLE, RESILIENT, ZERO-WASTE have 0
_reserve "EFFECTIVE: multi-a" P1 xs "check a"
_reserve "EFFECTIVE: multi-b" P1 xs "check b"

CHUMP_AMBIENT_OVERRIDE="$AMBIENT_T7" bash "$SCRIPT" >/dev/null 2>&1 || true

if [ -f "$AMBIENT_T7" ]; then
    _alert_count=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT_T7" || echo 0)
    if [ "${_alert_count:-0}" -ge 3 ]; then
        ok "Test 7: $( printf '%s' "$_alert_count") pillar_balance_alert events for 3 under-floor pillars"
    else
        fail "Test 7: expected >= 3 pillar_balance_alert events, got ${_alert_count:-0}"
    fi
else
    fail "Test 7: ambient.jsonl not written"
fi

rm -rf "$T7" "$TMP_DB7"
[ -n "$OLD_REPO" ] && export CHUMP_REPO="$OLD_REPO" || unset CHUMP_REPO

# ── Test 8: --dry-run does not write to ambient.jsonl ─────────────────────────
echo
echo "--- Test 8: --dry-run does not write to ambient.jsonl ---"
T8=$(mktemp -d)
TMP_DB8=$(_make_repo)
AMBIENT_T8="$T8/ambient.jsonl"

OLD_REPO="${CHUMP_REPO:-}"
export CHUMP_REPO="$TMP_DB8"
# Trigger alerts but with --dry-run
_reserve "EFFECTIVE: dry-a" P1 xs "check a"
# CREDIBLE, RESILIENT, ZERO-WASTE all empty → alerts would fire

CHUMP_AMBIENT_OVERRIDE="$AMBIENT_T8" bash "$SCRIPT" --dry-run >/dev/null 2>&1 || true

if [ ! -f "$AMBIENT_T8" ]; then
    ok "Test 8: --dry-run did not write ambient.jsonl"
else
    _lines=$(wc -l < "$AMBIENT_T8" 2>/dev/null || echo 0)
    if [ "${_lines:-0}" -eq 0 ]; then
        ok "Test 8: --dry-run produced empty ambient.jsonl (no events written)"
    else
        fail "Test 8: --dry-run wrote $_lines lines to ambient.jsonl — should not write"
    fi
fi

rm -rf "$T8" "$TMP_DB8"
[ -n "$OLD_REPO" ] && export CHUMP_REPO="$OLD_REPO" || unset CHUMP_REPO

# ── Test 9: CHUMP_PILLAR_BALANCE_DISABLED=1 bypasses all checks ──────────────
echo
echo "--- Test 9: CHUMP_PILLAR_BALANCE_DISABLED=1 bypasses ---"
T9=$(mktemp -d)
TMP_DB9=$(_make_repo)
AMBIENT_T9="$T9/ambient.jsonl"

OLD_REPO="${CHUMP_REPO:-}"
export CHUMP_REPO="$TMP_DB9"
# Empty DB — would normally fire all 4 pillar_balance_alert events

if CHUMP_PILLAR_BALANCE_DISABLED=1 CHUMP_AMBIENT_OVERRIDE="$AMBIENT_T9" bash "$SCRIPT" >/dev/null 2>&1; then
    ok "Test 9: CHUMP_PILLAR_BALANCE_DISABLED=1 exits 0 (bypassed)"
else
    fail "Test 9: CHUMP_PILLAR_BALANCE_DISABLED=1 should exit 0, not $?"
fi

if [ ! -f "$AMBIENT_T9" ] || ! grep -q "pillar_balance" "$AMBIENT_T9" 2>/dev/null; then
    ok "Test 9: CHUMP_PILLAR_BALANCE_DISABLED=1 emits no pillar_balance events"
else
    fail "Test 9: disabled mode should not emit pillar_balance events"
fi

rm -rf "$T9" "$TMP_DB9"
[ -n "$OLD_REPO" ] && export CHUMP_REPO="$OLD_REPO" || unset CHUMP_REPO

# ── Test 10: no declare -A / mapfile / readarray (Bash 3.2 compat) ────────────
echo
echo "--- Test 10: Bash 3.2 compat — no declare -A/n/mapfile/readarray ---"
_compat_ok=1
for _bad in "declare -A" "declare -n" "mapfile" "readarray"; do
    if grep -q "$_bad" "$SCRIPT" 2>/dev/null; then
        fail "Test 10: found Bash 4+ construct '$_bad' in script"
        _compat_ok=0
    fi
done
[ "$_compat_ok" -eq 1 ] && ok "Test 10: no Bash 4+ array constructs found"

# ── Results ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
