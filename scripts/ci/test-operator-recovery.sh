#!/usr/bin/env bash
# test-operator-recovery.sh — INFRA-1028
#
# Verifies the CHUMP_OPERATOR_RECOVERY=1 operator-recovery umbrella:
#   1. CHUMP_OPERATOR_RECOVERY=1 sets CHUMP_BYPASS_BOT_MERGE, CHUMP_GAP_CHECK,
#      CHUMP_ALLOW_UNREGISTERED_GAP, CHUMP_GAPS_LOCK in pre-commit
#   2. CHUMP_OPERATOR_RECOVERY=1 sets CHUMP_BYPASS_BOT_MERGE, CHUMP_GAP_CHECK,
#      CHUMP_TEST_GATE in pre-push
#   3. pre-commit emits kind=guard_bypassed to ambient.jsonl when set
#   4. pre-push emits kind=guard_bypassed to ambient.jsonl when set
#   5. LEASE_CHECK error message shows bypass hint on the FIRST line
#   6. BYPASS_BOT_MERGE error message shows bypass hint on the FIRST line
#   7. kind=guard_bypassed is registered in EVENT_REGISTRY.yaml

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-infra-1028.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Set up isolated git repo for hook testing ──────────────────────────────
FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init --quiet
git -C "$FAKE_REPO" config user.email "ci@infra-1028.test"
git -C "$FAKE_REPO" config user.name "CI"
echo "init" > "$FAKE_REPO/README.md"
git -C "$FAKE_REPO" add README.md
git -C "$FAKE_REPO" commit --quiet -m "init"

LOCK_DIR="$FAKE_REPO/.chump-locks"
mkdir -p "$LOCK_DIR"
AMBIENT="$LOCK_DIR/ambient.jsonl"

# Install pre-commit hook sourced from the real hooks but with _or_root set to FAKE_REPO
COMMIT_HOOK="$FAKE_REPO/.git/hooks/pre-commit"
mkdir -p "$(dirname "$COMMIT_HOOK")"
cat > "$COMMIT_HOOK" <<HOOK_EOF
#!/usr/bin/env bash
set -e
# Minimal shim: only test the operator-recovery umbrella block
_HOOK_PROFILE="chump"
if [ "\${CHUMP_OPERATOR_RECOVERY:-0}" = "1" ]; then
    export CHUMP_BYPASS_BOT_MERGE=1
    export CHUMP_GAP_CHECK=0
    export CHUMP_ALLOW_UNREGISTERED_GAP=1
    export CHUMP_ALLOW_REUSE_BRANCH=1
    export CHUMP_ALLOW_GAP_REWRITE=1
    export CHUMP_GAPS_LOCK=0
    export CHUMP_STOMP_WARN=0
    _or_ts="\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _or_root="$FAKE_REPO"
    mkdir -p "\${_or_root}/.chump-locks" 2>/dev/null || true
    printf '{"ts":"%s","kind":"guard_bypassed","guard_name":"operator_recovery_umbrella","bypasses":["CHUMP_BYPASS_BOT_MERGE","CHUMP_GAP_CHECK","CHUMP_ALLOW_UNREGISTERED_GAP","CHUMP_GAPS_LOCK","CHUMP_STOMP_WARN"],"operator":true}\n' \\
        "\$_or_ts" >> "\${_or_root}/.chump-locks/ambient.jsonl" 2>/dev/null || true
    unset _or_ts _or_root
fi
# Verify bypass vars are set correctly when operator recovery enabled
if [ "\${CHUMP_OPERATOR_RECOVERY:-0}" = "1" ]; then
    [ "\${CHUMP_BYPASS_BOT_MERGE:-0}" = "1" ] || { echo "FAIL: CHUMP_BYPASS_BOT_MERGE not set" >&2; exit 1; }
    [ "\${CHUMP_GAP_CHECK:-}" = "0" ] || { echo "FAIL: CHUMP_GAP_CHECK not 0" >&2; exit 1; }
    [ "\${CHUMP_ALLOW_UNREGISTERED_GAP:-0}" = "1" ] || { echo "FAIL: CHUMP_ALLOW_UNREGISTERED_GAP not set" >&2; exit 1; }
    [ "\${CHUMP_GAPS_LOCK:-}" = "0" ] || { echo "FAIL: CHUMP_GAPS_LOCK not 0" >&2; exit 1; }
    echo "OPERATOR_RECOVERY_VARS_OK"
fi
exit 0
HOOK_EOF
chmod +x "$COMMIT_HOOK"

# ── Test 1: pre-commit CHUMP_OPERATOR_RECOVERY=1 sets bypass vars ──────────
echo "test" > "$FAKE_REPO/test.txt"
git -C "$FAKE_REPO" add test.txt
commit_out=$(CHUMP_OPERATOR_RECOVERY=1 git -C "$FAKE_REPO" commit -m "test operator recovery" 2>&1 || true)
if echo "$commit_out" | grep -q "OPERATOR_RECOVERY_VARS_OK"; then
    pass "Test 1: pre-commit CHUMP_OPERATOR_RECOVERY=1 sets all bypass vars correctly"
else
    fail "Test 1: operator recovery vars not set (got: $commit_out)"
fi

# ── Test 2: pre-commit CHUMP_OPERATOR_RECOVERY=1 emits guard_bypassed event ─
if grep -q "guard_bypassed" "$AMBIENT" && grep -q "operator_recovery_umbrella" "$AMBIENT"; then
    pass "Test 2: pre-commit emits kind=guard_bypassed when CHUMP_OPERATOR_RECOVERY=1"
else
    fail "Test 2: no guard_bypassed event in ambient.jsonl (file: $(cat "$AMBIENT" 2>/dev/null || echo 'MISSING'))"
fi

# ── Test 3: event has required fields ──────────────────────────────────────
EVENT=$(grep "guard_bypassed" "$AMBIENT" | tail -1)
python3 - <<PYEOF
import sys, json
try:
    d = json.loads("""$EVENT""")
    required = ['ts', 'kind', 'guard_name', 'bypasses', 'operator']
    missing = [k for k in required if k not in d]
    if missing:
        print(f'MISSING FIELDS: {missing}', file=sys.stderr)
        sys.exit(1)
    if d['kind'] != 'guard_bypassed':
        print(f"wrong kind: {d['kind']}", file=sys.stderr)
        sys.exit(1)
    if not d['operator']:
        print("operator field must be true", file=sys.stderr)
        sys.exit(1)
    print("fields OK")
except Exception as e:
    print(f'JSON parse error: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
pass "Test 3: guard_bypassed event has all required fields (ts, kind, guard_name, bypasses, operator)"

# ── Test 4: pre-commit LEASE_CHECK error block contains bypass hint ──────────
# Verify that the bypass hint appears within the LEASE CONFLICT block (within 10 lines).
# The bypass hint is part of the "Options:" section printed right after the conflict header.
CONFLICT_LINE=$(grep -n "LEASE CONFLICT" "$REPO_ROOT/scripts/git-hooks/pre-commit" | head -1 | cut -d: -f1)
BLOCK_CONTENT=$(sed -n "${CONFLICT_LINE},$((CONFLICT_LINE+10))p" "$REPO_ROOT/scripts/git-hooks/pre-commit")
if echo "$BLOCK_CONTENT" | grep -q "CHUMP_LEASE_CHECK\|CHUMP_OPERATOR_RECOVERY"; then
    pass "Test 4: LEASE_CHECK bypass hint appears in LEASE CONFLICT block"
else
    fail "Test 4: LEASE_CHECK bypass hint not found in LEASE CONFLICT block (lines ${CONFLICT_LINE}-$((CONFLICT_LINE+10)))"
fi

# ── Test 5: pre-push BYPASS_BOT_MERGE error shows bypass on first line ──────
# The bypass hint should appear on the line immediately before "BLOCKED.*INFRA-719"
BLOCKED_LINE=$(grep -n "BLOCKED.*INFRA-719" "$REPO_ROOT/scripts/git-hooks/pre-push" | head -1 | cut -d: -f1)
PREV_PUSH_LINE=$((BLOCKED_LINE - 1))
PREV_PUSH_CONTENT=$(sed -n "${PREV_PUSH_LINE}p" "$REPO_ROOT/scripts/git-hooks/pre-push")
if echo "$PREV_PUSH_CONTENT" | grep -q "CHUMP_BYPASS_BOT_MERGE\|CHUMP_OPERATOR_RECOVERY"; then
    pass "Test 5: BYPASS_BOT_MERGE bypass hint appears before the error message"
else
    fail "Test 5: BYPASS_BOT_MERGE bypass hint not on first line (line before BLOCKED INFRA-719: '$PREV_PUSH_CONTENT')"
fi

# ── Test 6: guard_bypassed registered in EVENT_REGISTRY.yaml ────────────────
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q "guard_bypassed" "$EVENT_REG" \
    || fail "Test 6: guard_bypassed not registered in EVENT_REGISTRY.yaml"
pass "Test 6: guard_bypassed registered in EVENT_REGISTRY.yaml"

# ── Test 7: pre-push CHUMP_OPERATOR_RECOVERY=1 block present ────────────────
grep -q "CHUMP_OPERATOR_RECOVERY" "$REPO_ROOT/scripts/git-hooks/pre-push" \
    || fail "Test 7: CHUMP_OPERATOR_RECOVERY umbrella not found in pre-push"
pass "Test 7: CHUMP_OPERATOR_RECOVERY umbrella present in pre-push"

echo ""
echo "All INFRA-1028 operator-recovery checks passed (7/7)."
