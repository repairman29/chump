#!/usr/bin/env bash
# test-bug-fix-auto-promotion.sh — INFRA-627
#
# Validates that:
#  1. pr-triage-bot.yml exists and reserves gaps at P0 with the auto-filed marker
#  2. audit-priorities recognizes the auto-filed marker and exempts those P0s
#     from the P0 >5 budget rule (INFRA-627 AC)
#  3. audit-priorities JSON includes p0_auto_filed_count and p0_manual_count fields

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-627 bug-fix auto-promotion test ==="
echo

# 1. pr-triage-bot.yml exists and specifies P0 priority.
WORKFLOW="$REPO_ROOT/.github/workflows/pr-triage-bot.yml"
if [[ -f "$WORKFLOW" ]]; then
    ok "pr-triage-bot.yml exists"
else
    fail "pr-triage-bot.yml missing"
fi

if grep -q -- '--priority P0' "$WORKFLOW" 2>/dev/null; then
    ok "pr-triage-bot.yml uses --priority P0"
else
    fail "pr-triage-bot.yml missing --priority P0"
fi

if grep -q 'auto-filed by pr-triage-bot' "$WORKFLOW" 2>/dev/null; then
    ok "pr-triage-bot.yml sets auto-filed marker in notes"
else
    fail "pr-triage-bot.yml missing auto-filed marker"
fi

# 2. audit-priorities source recognizes the auto-filed marker.
if grep -q 'auto-filed by pr-triage-bot' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "main.rs audit-priorities references auto-filed marker"
else
    fail "main.rs audit-priorities missing auto-filed marker"
fi

if grep -q 'p0_manual_count\|p0_auto_filed' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "main.rs tracks auto-filed vs manual P0 counts separately"
else
    fail "main.rs missing p0_manual_count / p0_auto_filed split"
fi

# 3. Functional test: build binary and run against an isolated fixture DB.
# Resolve target dir via cargo metadata (handles shared/redirected target-dir configs).
TARGET_DIR=$(cargo metadata --no-deps --manifest-path "$REPO_ROOT/Cargo.toml" \
    --format-version 1 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('target_directory',''))" \
    2>/dev/null || echo "")
BIN="${TARGET_DIR:+$TARGET_DIR/debug/chump}"
BIN="${BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
    # Re-resolve after build.
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
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_RESERVE_VERIFY=0

# 3a. File 6 auto-filed P0 gaps — should NOT trigger P0 budget failure.
for i in $(seq 1 6); do
    GID=$("$BIN" gap reserve --domain INFRA --priority P0 --effort xs \
        --title "CREDIBLE: fix CI failure auto-$i" --quiet 2>/dev/null)
    "$BIN" gap set "$GID" \
        --notes "auto-filed by pr-triage-bot" \
        --acceptance-criteria "CI passes" 2>/dev/null
done

if "$BIN" gap audit-priorities >/dev/null 2>&1; then
    ok "exit 0 with 6 auto-filed P0s (budget exemption works)"
else
    fail "expected exit 0 with 6 auto-filed P0s — budget should not count auto-filed"
fi

JSON=$("$BIN" gap audit-priorities --json 2>/dev/null)

AUTO_COUNT=$(echo "$JSON" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('p0_auto_filed_count',0))" 2>/dev/null || echo 0)
if [[ "$AUTO_COUNT" -ge 6 ]]; then
    ok "p0_auto_filed_count >= 6 in JSON (got $AUTO_COUNT)"
else
    fail "p0_auto_filed_count should be >=6 (got $AUTO_COUNT)"
fi

MANUAL_COUNT=$(echo "$JSON" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('p0_manual_count',0))" 2>/dev/null || echo 0)
if [[ "$MANUAL_COUNT" -eq 0 ]]; then
    ok "p0_manual_count=0 (all P0s are auto-filed)"
else
    fail "p0_manual_count should be 0 (got $MANUAL_COUNT)"
fi

# 3b. Add 6 manual P0s (no auto-filed marker) — budget should now fail (>5 manual).
for i in $(seq 1 6); do
    GID=$("$BIN" gap reserve --domain INFRA --priority P0 --effort xs \
        --title "RESILIENT: manual P0 gap $i" --quiet 2>/dev/null)
    "$BIN" gap set "$GID" \
        --acceptance-criteria "done" 2>/dev/null
done

if ! "$BIN" gap audit-priorities >/dev/null 2>&1; then
    ok "exit 1 when manual P0 count exceeds 5"
else
    fail "expected exit 1 when manual P0 count > 5"
fi

# 3c. JSON has all expected fields.
for key in p0_count p0_manual_count p0_auto_filed_count p0_stuck_7d vague_pickable \
           double_encoded_depends_on missing_dep_refs open_with_closed_pr race_test_pollution; do
    if echo "$JSON" | grep -q "\"$key\""; then
        ok "JSON key $key present"
    else
        fail "JSON key $key missing"
    fi
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
