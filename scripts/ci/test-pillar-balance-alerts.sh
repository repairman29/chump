#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests for scripts/ops/pillar-balance-check.sh:
#   1.  Script exists and is executable
#   2.  Bash 3.2 compatible (no declare -A/-n/mapfile/readarray)
#   3.  Exit 0 on balanced fixture DB
#   4.  Exit 1 when a pillar has 0 pickable gaps → kind=pillar_balance_alert
#   5.  Alert JSON has correct fields: ts, kind, pillar, count, floor
#   6.  Exit 1 when a pillar > 50% of pool → kind=pillar_balance_overweight
#   7.  Overweight JSON has correct fields: ts, kind, pillar, count, pct
#   8.  CHUMP_PILLAR_BALANCE_CHECK=0 bypasses → exit 0, no ambient write
#   9.  CHUMP_PILLAR_BALANCE_DRY_RUN=1 computes but skips ambient write
#   10. audit-priorities calls pillar-balance-check.sh (integration check)
#   11. Gaps with vague AC (no acceptance_criteria) excluded from pickable pool
#   12. Vague-AC exclusion: no alert when all non-vague gaps are balanced

set -uo pipefail

PASS=0
FAIL=0
ok()   { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts test ==="
echo

# ── 1. Script exists and is executable ───────────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh missing or not executable at $SCRIPT"
fi

# ── 2. No declare -A / declare -n / mapfile / readarray (Bash 3.2 compat) ────
if grep -qE 'declare -[AnN]|mapfile|readarray' "$SCRIPT" 2>/dev/null; then
    fail "script uses Bash 4+ features (declare -A/-n, mapfile, readarray)"
else
    ok "script is Bash 3.2 compatible (no declare -A/-n/mapfile/readarray)"
fi

# ── Build binary ──────────────────────────────────────────────────────────────
TARGET_DIR="${CARGO_TARGET_DIR:-$(cargo metadata --no-deps --format-version 1 \
    --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])' \
    2>/dev/null || echo "$REPO_ROOT/target")}"

BIN="${TARGET_DIR}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

# ── Fixture helper ────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

new_fixture() {
    local dir
    dir="$(mktemp -d "$TMP/fixture.XXXXXX")"
    mkdir -p "$dir/.chump-locks"
    export CHUMP_REPO="$dir"
    export CHUMP_HOME="$dir"
    export CHUMP_ALLOW_MAIN_WORKTREE=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export CHUMP_BIN="$BIN"
    echo "$dir"
}

reserve_gap() {
    # reserve_gap <domain> <priority> <effort> <title> [<ac>]
    local dom="$1" prio="$2" eff="$3" title="$4"
    local ac="${5:-}"
    local id
    id=$("$BIN" gap reserve --domain "$dom" --priority "$prio" --effort "$eff" \
        --title "$title" --quiet 2>/dev/null)
    if [[ -n "$ac" && -n "$id" ]]; then
        "$BIN" gap set "$id" --acceptance-criteria "$ac" 2>/dev/null || true
    fi
    echo "${id:-}"
}

# ── 3. Exit 0 on balanced fixture ────────────────────────────────────────────
FDIR="$(new_fixture)"
AMBIENT="$FDIR/.chump-locks/ambient.jsonl"

for domain in EFFECTIVE CREDIBLE RESILIENT; do
    reserve_gap "$domain" P1 xs "${domain}: gap-one" "AC: ships" > /dev/null
    reserve_gap "$domain" P1 xs "${domain}: gap-two" "AC: ships" > /dev/null
done
reserve_gap INFRA P1 xs "ZERO-WASTE: gap-one" "AC: ships" > /dev/null
reserve_gap INFRA P1 xs "ZERO-WASTE: gap-two" "AC: ships" > /dev/null

if CHUMP_PILLAR_BALANCE_DRY_RUN=1 CHUMP_AMBIENT_LOG="$AMBIENT" \
   bash "$SCRIPT" > /dev/null 2>&1; then
    ok "exit 0 on balanced fixture"
else
    fail "expected exit 0 on balanced fixture"
fi

# ── 4. Exit 1 when pillar has 0 pickable gaps → alert emitted ────────────────
FDIR2="$(new_fixture)"
AMBIENT2="$FDIR2/.chump-locks/ambient.jsonl"

for domain in EFFECTIVE CREDIBLE RESILIENT; do
    reserve_gap "$domain" P1 xs "${domain}: gap-one" "AC: ships" > /dev/null
    reserve_gap "$domain" P1 xs "${domain}: gap-two" "AC: ships" > /dev/null
done
# ZERO-WASTE intentionally empty → 0 pickable

ALERT_EXIT=0
CHUMP_PILLAR_BALANCE_DRY_RUN=0 CHUMP_AMBIENT_LOG="$AMBIENT2" \
    bash "$SCRIPT" > /dev/null 2>&1 || ALERT_EXIT=$?

if [[ "$ALERT_EXIT" -eq 1 ]]; then
    ok "exit 1 when ZERO-WASTE has 0 pickable gaps"
else
    fail "expected exit 1 when ZERO-WASTE has 0 pickable gaps (got $ALERT_EXIT)"
fi

if [[ -f "$AMBIENT2" ]] && grep -q '"kind":"pillar_balance_alert"' "$AMBIENT2"; then
    ok "kind=pillar_balance_alert emitted to ambient.jsonl"
else
    fail "kind=pillar_balance_alert not found in ambient.jsonl"
fi

# ── 5. Alert JSON fields: ts, kind, pillar, count, floor ─────────────────────
if [[ -f "$AMBIENT2" ]]; then
    ALERT_LINE=$(grep '"kind":"pillar_balance_alert"' "$AMBIENT2" | head -1)
    FIELDS_OK=1
    for field in '"ts"' '"kind"' '"pillar"' '"count"' '"floor"'; do
        echo "$ALERT_LINE" | grep -q "$field" || { FIELDS_OK=0; break; }
    done
    if [[ "$FIELDS_OK" -eq 1 ]]; then
        ok "pillar_balance_alert JSON has required fields (ts, kind, pillar, count, floor)"
    else
        fail "pillar_balance_alert JSON missing required field(s): $ALERT_LINE"
    fi

    if echo "$ALERT_LINE" | grep -q '"floor":2'; then
        ok "pillar_balance_alert floor=2"
    else
        fail "pillar_balance_alert floor value not 2 in: $ALERT_LINE"
    fi
fi

# ── 6. Exit 1 when pillar > 50% → overweight emitted ─────────────────────────
FDIR3="$(new_fixture)"
AMBIENT3="$FDIR3/.chump-locks/ambient.jsonl"

# 3 EFFECTIVE + 1 CREDIBLE → EFFECTIVE = 75% (>50%)
reserve_gap EFFECTIVE P1 xs "EFFECTIVE: gap-one"   "AC: ships" > /dev/null
reserve_gap EFFECTIVE P1 xs "EFFECTIVE: gap-two"   "AC: ships" > /dev/null
reserve_gap EFFECTIVE P1 xs "EFFECTIVE: gap-three" "AC: ships" > /dev/null
reserve_gap CREDIBLE  P1 xs "CREDIBLE: gap-one"    "AC: ships" > /dev/null

OW_EXIT=0
CHUMP_PILLAR_BALANCE_DRY_RUN=0 CHUMP_AMBIENT_LOG="$AMBIENT3" \
    bash "$SCRIPT" > /dev/null 2>&1 || OW_EXIT=$?

if [[ "$OW_EXIT" -eq 1 ]]; then
    ok "exit 1 when EFFECTIVE overweight (>50% of pool)"
else
    fail "expected exit 1 when EFFECTIVE overweight (got $OW_EXIT)"
fi

if [[ -f "$AMBIENT3" ]] && grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT3"; then
    ok "kind=pillar_balance_overweight emitted to ambient.jsonl"
else
    fail "kind=pillar_balance_overweight not found in ambient.jsonl"
fi

# ── 7. Overweight JSON fields: ts, kind, pillar, count, pct ──────────────────
if [[ -f "$AMBIENT3" ]]; then
    OW_LINE=$(grep '"kind":"pillar_balance_overweight"' "$AMBIENT3" | head -1)
    OW_FIELDS_OK=1
    for field in '"ts"' '"kind"' '"pillar"' '"count"' '"pct"'; do
        echo "$OW_LINE" | grep -q "$field" || { OW_FIELDS_OK=0; break; }
    done
    if [[ "$OW_FIELDS_OK" -eq 1 ]]; then
        ok "pillar_balance_overweight JSON has required fields (ts, kind, pillar, count, pct)"
    else
        fail "pillar_balance_overweight JSON missing required field(s): $OW_LINE"
    fi
fi

# ── 8. CHUMP_PILLAR_BALANCE_CHECK=0 bypass → exit 0, no ambient write ────────
FDIR4="$(new_fixture)"
AMBIENT4="$FDIR4/.chump-locks/ambient.jsonl"

BYPASS_EXIT=0
CHUMP_PILLAR_BALANCE_CHECK=0 CHUMP_AMBIENT_LOG="$AMBIENT4" \
    bash "$SCRIPT" > /dev/null 2>&1 || BYPASS_EXIT=$?

if [[ "$BYPASS_EXIT" -eq 0 ]]; then
    ok "CHUMP_PILLAR_BALANCE_CHECK=0 exits 0"
else
    fail "expected exit 0 with bypass (got $BYPASS_EXIT)"
fi

if [[ ! -f "$AMBIENT4" ]] || ! grep -q '"kind":"pillar_balance' "$AMBIENT4" 2>/dev/null; then
    ok "bypass: no events written to ambient.jsonl"
else
    fail "bypass: unexpected events in ambient.jsonl"
fi

# ── 9. CHUMP_PILLAR_BALANCE_DRY_RUN=1 computes but skips ambient write ────────
FDIR5="$(new_fixture)"
AMBIENT5="$FDIR5/.chump-locks/ambient.jsonl"

reserve_gap EFFECTIVE P1 xs "EFFECTIVE: gap-one" "AC: ships" > /dev/null
# Other pillars empty → would emit alerts if not dry run

DRY_EXIT=0
CHUMP_PILLAR_BALANCE_DRY_RUN=1 CHUMP_AMBIENT_LOG="$AMBIENT5" \
    bash "$SCRIPT" > /dev/null 2>&1 || DRY_EXIT=$?

if [[ "$DRY_EXIT" -eq 1 ]]; then
    ok "dry-run: exits 1 (alerts detected)"
else
    fail "expected exit 1 in dry-run with unbalanced pillars (got $DRY_EXIT)"
fi

if [[ ! -f "$AMBIENT5" ]] || ! grep -q '"kind":"pillar_balance' "$AMBIENT5" 2>/dev/null; then
    ok "dry-run: no events written to ambient.jsonl"
else
    fail "dry-run: unexpected events written to ambient.jsonl"
fi

# ── 10. audit-priorities wires pillar-balance-check.sh ───────────────────────
if grep -q 'pillar.balance.check\|pillar_balance_check' "$REPO_ROOT/src/main.rs"; then
    ok "src/main.rs references pillar-balance-check.sh"
else
    fail "src/main.rs does not call pillar-balance-check.sh (AC 5 not met)"
fi

# ── 11. Vague-AC gaps excluded from pickable pool ────────────────────────────
FDIR6="$(new_fixture)"
AMBIENT6="$FDIR6/.chump-locks/ambient.jsonl"

reserve_gap EFFECTIVE P1 xs "EFFECTIVE: gap-one" "AC: ships" > /dev/null
reserve_gap EFFECTIVE P1 xs "EFFECTIVE: gap-two" "AC: ships" > /dev/null
# CREDIBLE gap with NO AC → vague, excluded
reserve_gap CREDIBLE P1 xs "CREDIBLE: vague-gap" "" > /dev/null

VAGUE_OUT=$(CHUMP_PILLAR_BALANCE_DRY_RUN=1 CHUMP_AMBIENT_LOG="$AMBIENT6" \
    bash "$SCRIPT" 2>/dev/null || true)

# CREDIBLE should show 0 (vague gap excluded)
CREDIBLE_SHOWN=$(echo "$VAGUE_OUT" | awk '/CREDIBLE/{print $NF}' | head -1)
if [[ "${CREDIBLE_SHOWN:-1}" == "0" ]]; then
    ok "vague-AC gap excluded from CREDIBLE pillar count"
else
    fail "expected CREDIBLE=0 when only gap has vague AC (got: ${CREDIBLE_SHOWN:-?})"
fi

# ── 12. Balanced check: no alert when all non-vague gaps cover pillars ────────
FDIR7="$(new_fixture)"
AMBIENT7="$FDIR7/.chump-locks/ambient.jsonl"

for domain in EFFECTIVE CREDIBLE RESILIENT; do
    reserve_gap "$domain" P1 xs "${domain}: gap-a" "AC: real" > /dev/null
    reserve_gap "$domain" P1 xs "${domain}: gap-b" "AC: real" > /dev/null
done
reserve_gap INFRA P1 xs "ZERO-WASTE: gap-a" "AC: real" > /dev/null
reserve_gap INFRA P1 xs "ZERO-WASTE: gap-b" "AC: real" > /dev/null

BALANCED_EXIT=0
CHUMP_PILLAR_BALANCE_DRY_RUN=1 CHUMP_AMBIENT_LOG="$AMBIENT7" \
    bash "$SCRIPT" > /dev/null 2>&1 || BALANCED_EXIT=$?

if [[ "$BALANCED_EXIT" -eq 0 ]]; then
    ok "no alert when all 4 pillars have 2+ non-vague pickable gaps"
else
    fail "expected exit 0 on fully-balanced fixture (got $BALANCED_EXIT)"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
