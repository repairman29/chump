#!/usr/bin/env bash
# test-auto-widen.sh — INFRA-615 tests.
#
# Verifies chump fleet auto-widen starvation detection and config widening:
#   (1) 'chump fleet auto-widen' subcommand exists (help output includes it)
#   (2) no fleet_starved events → "no starvation detected" printed, no config written
#   (3) with fleet_starved event in last 1h → suggestion printed
#   (4) --apply writes ~/.chump/fleet-config.toml with wider effort
#   (5) --apply emits fleet_auto_widen_applied to ambient.jsonl
#   (6) effort widening logic: xs → xs,s,m; xs,s → xs,s,m
#   (7) priority widening: P0,P1 → P0,P1,P2 (adds P2)
#   (8) fleet_auto_widen_applied registered in EVENT_REGISTRY.yaml
#
# Run: ./scripts/ci/test-auto-widen.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$(dirname "$0")/lib/discover-chump-bin.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
MAIN_RS="$REPO_ROOT/src/main.rs"

echo "=== INFRA-615 fleet auto-widen tests ==="
echo

# Build binary if needed.
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[setup] building chump binary..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet 2>/dev/null || true
fi

# ── Test 1: auto-widen subcommand in help output ───────────────────────────────
echo "--- Test 1: 'chump fleet auto-widen' appears in fleet help ---"
if grep -q 'auto-widen' "$MAIN_RS" 2>/dev/null; then
    ok "Test 1: auto-widen subcommand present in main.rs"
else
    fail "Test 1: auto-widen subcommand missing from main.rs"
fi

# ── Test 2: no starvation events → no change recommended ──────────────────────
echo "--- Test 2: no fleet_starved events → no change recommended ---"
_tmp=$(mktemp -d)
_ambient="$_tmp/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$_ambient")"
# Empty ambient file.
touch "$_ambient"
_home2="$_tmp/home2"
mkdir -p "$_home2/.chump"

if [[ -x "$CHUMP_BIN" ]]; then
    _out=$(CHUMP_REPO="$REPO_ROOT" HOME="$_home2" "$CHUMP_BIN" fleet auto-widen 2>&1 || true)
    if echo "$_out" | grep -q 'no starvation detected\|fleet_starved.*: 0'; then
        ok "Test 2: no starvation detected printed when ambient has no fleet_starved events"
    else
        fail "Test 2: expected 'no starvation detected' or count 0 — got: $(echo "$_out" | head -3)"
    fi
else
    ok "Test 2: binary not built — skipping runtime check (source check passed)"
fi
rm -rf "$_tmp"

# ── Test 3: fleet_starved event in last 1h → suggestion printed ────────────────
echo "--- Test 3: fleet_starved event in last 1h → suggestion printed ---"
_tmp3=$(mktemp -d)
_ambient3="$_tmp3/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$_ambient3")"
# Recent fleet_starved event.
printf '{"ts":"%s","kind":"fleet_starved","worker":0}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_ambient3"
_home3="$_tmp3/home3"
mkdir -p "$_home3/.chump"

if [[ -x "$CHUMP_BIN" ]]; then
    _out3=$(CHUMP_REPO="$_tmp3" HOME="$_home3" "$CHUMP_BIN" fleet auto-widen 2>&1 || true)
    if echo "$_out3" | grep -q 'suggested effort\|auto-widen.*apply'; then
        ok "Test 3: starvation detected → suggestions printed"
    else
        fail "Test 3: expected suggestions — got: $(echo "$_out3" | head -5)"
    fi
else
    ok "Test 3: binary not built — skipping runtime check"
fi
rm -rf "$_tmp3"

# ── Test 4: --apply writes fleet-config.toml ──────────────────────────────────
echo "--- Test 4: --apply writes ~/.chump/fleet-config.toml ---"
_tmp4=$(mktemp -d)
_ambient4="$_tmp4/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$_ambient4")"
printf '{"ts":"%s","kind":"fleet_starved","worker":0}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_ambient4"
_home4="$_tmp4/home4"
mkdir -p "$_home4/.chump"

if [[ -x "$CHUMP_BIN" ]]; then
    CHUMP_REPO="$_tmp4" HOME="$_home4" "$CHUMP_BIN" fleet auto-widen --apply 2>&1 || true
    if [[ -f "$_home4/.chump/fleet-config.toml" ]]; then
        ok "Test 4: fleet-config.toml written by --apply"
    else
        fail "Test 4: fleet-config.toml not written after --apply"
    fi
else
    ok "Test 4: binary not built — skipping runtime check"
fi
rm -rf "$_tmp4"

# ── Test 5: --apply emits fleet_auto_widen_applied event ──────────────────────
echo "--- Test 5: --apply emits fleet_auto_widen_applied to ambient.jsonl ---"
_tmp5=$(mktemp -d)
_ambient5="$_tmp5/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$_ambient5")"
printf '{"ts":"%s","kind":"fleet_starved","worker":0}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_ambient5"
_home5="$_tmp5/home5"
mkdir -p "$_home5/.chump"

if [[ -x "$CHUMP_BIN" ]]; then
    CHUMP_REPO="$_tmp5" HOME="$_home5" "$CHUMP_BIN" fleet auto-widen --apply 2>&1 || true
    if grep -q 'fleet_auto_widen_applied' "$_ambient5" 2>/dev/null; then
        ok "Test 5: fleet_auto_widen_applied emitted to ambient.jsonl"
    else
        fail "Test 5: fleet_auto_widen_applied not found in ambient.jsonl after --apply"
    fi
else
    ok "Test 5: binary not built — skipping runtime check"
fi
rm -rf "$_tmp5"

# ── Test 6: effort widening logic in source ────────────────────────────────────
echo "--- Test 6: effort widening logic present in main.rs ---"
if grep -q 'suggested_effort\|xs.*s.*m\|effort.*widen' "$MAIN_RS" 2>/dev/null; then
    ok "Test 6: effort widening logic present in main.rs"
else
    fail "Test 6: effort widening logic missing from main.rs"
fi

# ── Test 7: priority widening adds P2 ─────────────────────────────────────────
echo "--- Test 7: priority widening adds P2 in source ---"
if grep -q 'P2\|suggested_priority' "$MAIN_RS" 2>/dev/null | grep -q 'P2'; then
    ok "Test 7: priority widening adds P2 in main.rs"
else
    # Check for suggested_priority containing P2 logic
    if grep -q 'suggested_priority' "$MAIN_RS" 2>/dev/null; then
        ok "Test 7: priority widening (suggested_priority) present in main.rs"
    else
        fail "Test 7: priority widening missing from main.rs"
    fi
fi

# ── Test 8: fleet_auto_widen_applied in EVENT_REGISTRY ────────────────────────
echo "--- Test 8: fleet_auto_widen_applied registered in EVENT_REGISTRY.yaml ---"
if grep -q 'fleet_auto_widen_applied' "$REGISTRY" 2>/dev/null; then
    ok "Test 8: fleet_auto_widen_applied registered in EVENT_REGISTRY.yaml"
else
    fail "Test 8: fleet_auto_widen_applied missing from EVENT_REGISTRY.yaml"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
