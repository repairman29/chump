#!/usr/bin/env bash
# test-pillar-balance-alerts.sh — INFRA-902
#
# Validates scripts/ops/pillar-balance-check.sh:
#  1. script exists and is Bash-3.2 compatible (no declare -A/-n/mapfile/readarray)
#  2. mkdir -p's the ambient log's parent dir before appending
#  3. emits kind=pillar_balance_alert when a pillar has <2 pickable, with
#     pillar/count/floor fields
#  4. emits kind=pillar_balance_overweight when a pillar has >50% of the
#     pickable pool, with pillar/count/pct fields
#  5. exits non-zero when any alert fired, exit 0 when balanced
#  6. `chump gap audit-priorities` wires in the script and surfaces its
#     result in both text and --json output

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

echo "=== INFRA-902 pillar-balance-alerts test ==="
echo

# 1. Script exists.
if [[ -f "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists"
else
    fail "pillar-balance-check.sh missing"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# 2. Bash-3.2 compatibility — no Bash-4+-only constructs.
if grep -qE 'declare -A|declare -n|mapfile|readarray' "$SCRIPT"; then
    fail "script uses Bash-4+-only constructs (declare -A/-n, mapfile, readarray)"
else
    ok "no Bash-4+-only constructs (declare -A/-n, mapfile, readarray)"
fi

# 3. mkdir -p ambient dir before append.
if grep -q 'mkdir -p.*dirname.*AMBIENT' "$SCRIPT"; then
    ok "script mkdir -p's ambient log parent dir"
else
    fail "script does not mkdir -p ambient log parent dir"
fi

# 4. Verify on a real Bash-3.2-ish shell invocation (Linux bash is a superset;
#    a syntax-only check with `bash -n` catches the common macOS-3.2 breakers).
if bash -n "$SCRIPT" 2>/dev/null; then
    ok "script passes bash -n syntax check"
else
    fail "script fails bash -n syntax check"
fi

# Resolve/build the chump binary via cargo metadata (INFRA-481: shared target-dir).
TARGET_DIR=$(cargo metadata --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" \
    --format-version 1 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('target_directory',''))" \
    2>/dev/null || echo "")
BIN="${TARGET_DIR:+$TARGET_DIR/debug/chump}"
BIN="${BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    TARGET_DIR=$(cargo metadata --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" \
        --format-version 1 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('target_directory',''))" \
        2>/dev/null || echo "")
    BIN="${TARGET_DIR:+$TARGET_DIR/debug/chump}"
    BIN="${BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_BIN="$BIN"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_RESERVE_VERIFY=0
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
export CHUMP_AMBIENT_LOG="$AMBIENT"

reserve_pickable() {
    # reserve_pickable <pillar-prefix> <n>
    local prefix="$1"
    local n="$2"
    for i in $(seq 1 "$n"); do
        GID=$("$BIN" gap reserve --domain INFRA --priority P1 --effort s \
            --title "${prefix}: fixture pickable gap $i $RANDOM" --quiet 2>/dev/null)
        "$BIN" gap set "$GID" --acceptance-criteria "concrete testable AC $i" 2>/dev/null
    done
}

# 5a. Starved fixture — only EFFECTIVE has 3 pickable, others have 0.
# Should fire pillar_balance_alert for CREDIBLE/RESILIENT/ZERO-WASTE (each <2)
# and pillar_balance_overweight for EFFECTIVE (3/3 = 100% > 50%).
reserve_pickable "EFFECTIVE" 3

set +e
"$SCRIPT" >/tmp/pbc-out-starved.txt 2>&1
STARVED_EXIT=$?
set -e 2>/dev/null || true

if [[ "$STARVED_EXIT" -ne 0 ]]; then
    ok "exit non-zero when pillars are starved/overweight"
else
    fail "expected non-zero exit with starved pillars (got 0)"
fi

if [[ -f "$AMBIENT" ]]; then
    ok "ambient.jsonl created (mkdir -p worked)"
else
    fail "ambient.jsonl not created"
fi

ALERT_COUNT=$(grep -c '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null)
ALERT_COUNT="${ALERT_COUNT:-0}"
if [[ "$ALERT_COUNT" -ge 3 ]]; then
    ok "pillar_balance_alert fired for >=3 starved pillars (got $ALERT_COUNT)"
else
    fail "expected >=3 pillar_balance_alert events (got $ALERT_COUNT)"
fi

if grep -q '"kind":"pillar_balance_alert".*"pillar":"CREDIBLE".*"count":0.*"floor":2' "$AMBIENT"; then
    ok "pillar_balance_alert schema has pillar/count/floor fields"
else
    fail "pillar_balance_alert missing expected pillar/count/floor schema"
fi

OVERWEIGHT_COUNT=$(grep -c '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null)
OVERWEIGHT_COUNT="${OVERWEIGHT_COUNT:-0}"
if [[ "$OVERWEIGHT_COUNT" -ge 1 ]]; then
    ok "pillar_balance_overweight fired for the dominant pillar"
else
    fail "expected >=1 pillar_balance_overweight event (got $OVERWEIGHT_COUNT)"
fi

if grep -q '"kind":"pillar_balance_overweight".*"pillar":"EFFECTIVE".*"count":3.*"pct":100' "$AMBIENT"; then
    ok "pillar_balance_overweight schema has pillar/count/pct fields"
else
    fail "pillar_balance_overweight missing expected pillar/count/pct schema"
fi

# 5b. Balanced fixture — bring the other 3 pillars up to 3 pickable each too.
rm -f "$AMBIENT"
reserve_pickable "CREDIBLE" 3
reserve_pickable "RESILIENT" 3
reserve_pickable "ZERO-WASTE" 3

set +e
"$SCRIPT" >/tmp/pbc-out-balanced.txt 2>&1
BALANCED_EXIT=$?
set -e 2>/dev/null || true

if [[ "$BALANCED_EXIT" -eq 0 ]]; then
    ok "exit 0 when all 4 pillars are balanced (3 pickable each)"
else
    fail "expected exit 0 with balanced pillars (got $BALANCED_EXIT)"
    cat /tmp/pbc-out-balanced.txt
fi

if [[ ! -s "$AMBIENT" ]] || ! grep -q 'pillar_balance' "$AMBIENT" 2>/dev/null; then
    ok "no pillar_balance alerts emitted when balanced"
else
    fail "unexpected pillar_balance alert emitted while balanced"
fi

# 5c. --json output shape.
JSON_OUT=$("$SCRIPT" --json 2>/dev/null)
if echo "$JSON_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'total' in d and 'pillars' in d and 'alerts_fired' in d" 2>/dev/null; then
    ok "--json output has total/pillars/alerts_fired fields"
else
    fail "--json output missing expected fields"
fi

# 6. chump gap audit-priorities wires in pillar-balance-check.sh.
if grep -q 'pillar-balance-check.sh' "$REPO_ROOT/src/main.rs"; then
    ok "main.rs audit-priorities invokes pillar-balance-check.sh"
else
    fail "main.rs audit-priorities does not reference pillar-balance-check.sh"
fi

AUDIT_JSON=$("$BIN" gap audit-priorities --json 2>/dev/null)
if echo "$AUDIT_JSON" | grep -q '"pillar_balance"'; then
    ok "audit-priorities --json includes pillar_balance field"
else
    fail "audit-priorities --json missing pillar_balance field"
fi

AUDIT_TEXT=$("$BIN" gap audit-priorities 2>/dev/null)
if echo "$AUDIT_TEXT" | grep -qi "pillar balance"; then
    ok "audit-priorities text output includes pillar balance section"
else
    fail "audit-priorities text output missing pillar balance section"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
