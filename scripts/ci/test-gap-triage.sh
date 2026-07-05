#!/usr/bin/env bash
# test-gap-triage.sh — INFRA-942
#
# Validates the `chump gap triage` subcommand:
#  - subcommand wired in main.rs
#  - --json output contains expected fields
#  - exit-0 on a clean fixture DB
#  - exit-1 when actionable items found
#  - false-dep detection: depends_on → done gap → strip-dep
#  - too-large detection: effort=l|xl, no sub-gaps → decompose
#  - vague-ac detection: empty or TODO AC → add-ac
#  - --apply strips false deps from depends_on

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-942 gap triage test ==="
echo

# 1. Subcommand wired in main.rs.
if grep -q '"triage"' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "triage arm in main.rs"
else
    fail "triage arm missing from main.rs"
fi

# 2. Help text lists triage.
if grep -q 'triage' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "triage mentioned in help/match"
else
    fail "triage not mentioned in main.rs"
fi

# 3. Build binary — honour CARGO_TARGET_DIR if set (INFRA-1063).
# The worktree shares the workspace target dir with the main checkout;
# resolve the canonical target dir via cargo metadata so CARGO_TARGET_DIR
# overrides are respected automatically.
_TARGET_DIR="$(cargo metadata --no-deps --format-version 1 \
    --manifest-path "$REPO_ROOT/Cargo.toml" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])" \
    2>/dev/null || echo "${CARGO_TARGET_DIR:-$REPO_ROOT/target}")"
BIN="$_TARGET_DIR/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found at $BIN after build — cannot run functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1

# 4a. Empty DB → exit 0.
if "$BIN" gap triage >/dev/null 2>&1; then
    ok "exit 0 on empty registry"
else
    fail "expected exit 0 on empty registry"
fi

# 4b. --json on empty DB → valid JSON array.
JSON=$("$BIN" gap triage --json 2>/dev/null)
if echo "$JSON" | python3 -c "import sys,json; arr=json.load(sys.stdin); assert isinstance(arr, list)" 2>/dev/null; then
    ok "--json returns JSON array"
else
    fail "--json output is not a JSON array"
fi

# 4c. vague-ac: open gap with empty AC → reason=vague-ac, action=add-ac, exit 1.
"$BIN" gap reserve --domain INFRA --priority P1 --effort xs \
    --title "triage-fixture-vague" --quiet 2>/dev/null
if ! "$BIN" gap triage >/dev/null 2>&1; then
    ok "exit 1 when vague-ac gap present"
else
    fail "expected exit 1 with vague-ac gap"
fi

REASON=$("$BIN" gap triage --json 2>/dev/null \
    | python3 -c "import sys,json; items=json.load(sys.stdin); reasons=[i['reason'] for i in items]; print(','.join(reasons))" 2>/dev/null || echo "")
if echo "$REASON" | grep -q "vague-ac"; then
    ok "vague-ac reason detected"
else
    fail "vague-ac reason not found (got: $REASON)"
fi

ACTION=$("$BIN" gap triage --json 2>/dev/null \
    | python3 -c "import sys,json; items=json.load(sys.stdin); actions=[i['recommended_action'] for i in items if i['reason']=='vague-ac']; print(','.join(actions))" 2>/dev/null || echo "")
if echo "$ACTION" | grep -q "add-ac"; then
    ok "vague-ac → add-ac recommended_action"
else
    fail "vague-ac should recommend add-ac (got: $ACTION)"
fi

# 4d. too-large: open gap with effort=l → reason=too-large, action=decompose.
"$BIN" gap reserve --domain INFRA --priority P2 --effort l \
    --title "triage-fixture-large" --quiet 2>/dev/null
LARGE_REASON=$("$BIN" gap triage --json 2>/dev/null \
    | python3 -c "import sys,json; items=json.load(sys.stdin); r=[i['reason'] for i in items if 'large' in i['title']]; print(','.join(r))" 2>/dev/null || echo "")
if echo "$LARGE_REASON" | grep -q "too-large"; then
    ok "too-large reason detected for effort=l gap"
else
    fail "too-large reason not found for effort=l gap (got: $LARGE_REASON)"
fi

LARGE_ACTION=$("$BIN" gap triage --json 2>/dev/null \
    | python3 -c "import sys,json; items=json.load(sys.stdin); a=[i['recommended_action'] for i in items if i['reason']=='too-large']; print(','.join(a))" 2>/dev/null || echo "")
if echo "$LARGE_ACTION" | grep -q "decompose"; then
    ok "too-large → decompose recommended_action"
else
    fail "too-large should recommend decompose (got: $LARGE_ACTION)"
fi

# 4e. false-dep: open gap depending on a done gap → strip-dep, --apply fixes it.
# Reserve two gaps
"$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "triage-fixture-dep-parent" --quiet 2>/dev/null
PARENT_ID=$("$BIN" gap list --status open --json 2>/dev/null \
    | python3 -c "import sys,json; items=json.load(sys.stdin); r=[i['id'] for i in items if 'dep-parent' in i['title']]; print(r[-1])" 2>/dev/null || echo "")

"$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "triage-fixture-dep-child" --quiet 2>/dev/null
CHILD_ID=$("$BIN" gap list --status open --json 2>/dev/null \
    | python3 -c "import sys,json; items=json.load(sys.stdin); r=[i['id'] for i in items if 'dep-child' in i['title']]; print(r[-1])" 2>/dev/null || echo "")

if [[ -n "$PARENT_ID" && -n "$CHILD_ID" ]]; then
    # Set child to depend on parent, then mark parent done
    "$BIN" gap set "$CHILD_ID" --depends-on "$PARENT_ID" --quiet 2>/dev/null || true
    CHUMP_BYPASS_CLOSED_PR_GUARD=1 "$BIN" gap set "$PARENT_ID" --status done --quiet 2>/dev/null || true

    FALSE_DEP_REASON=$("$BIN" gap triage --json 2>/dev/null \
        | python3 -c "import sys,json; items=json.load(sys.stdin); r=[i['reason'] for i in items if i.get('id')=='$CHILD_ID']; print(','.join(r))" 2>/dev/null || echo "")
    if echo "$FALSE_DEP_REASON" | grep -q "false-dep"; then
        ok "false-dep detected when depends_on points at done gap"
    else
        fail "false-dep not detected (child=$CHILD_ID, parent=$PARENT_ID, reasons=$FALSE_DEP_REASON)"
    fi

    # --apply should strip the false dep
    "$BIN" gap triage --apply >/dev/null 2>&1 || true
    DEP_AFTER=$("$BIN" gap show "$CHILD_ID" 2>/dev/null | grep -i "depends_on" || echo "none")
    # After apply the dep should be empty / stripped
    # Check via JSON: triage should no longer flag child as false-dep
    FALSE_DEP_AFTER=$("$BIN" gap triage --json 2>/dev/null \
        | python3 -c "import sys,json; items=json.load(sys.stdin); r=[i for i in items if i.get('id')=='$CHILD_ID' and i['reason']=='false-dep']; print(len(r))" 2>/dev/null || echo "1")
    if [[ "$FALSE_DEP_AFTER" == "0" ]]; then
        ok "--apply stripped false dep successfully"
    else
        fail "--apply did not strip false dep (still flagged after apply)"
    fi
else
    fail "could not reserve fixture gaps for false-dep test (PARENT=$PARENT_ID CHILD=$CHILD_ID)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
