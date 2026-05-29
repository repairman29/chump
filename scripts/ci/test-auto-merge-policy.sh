#!/usr/bin/env bash
# scripts/ci/test-auto-merge-policy.sh — INFRA-1489 smoke test.
#
# Asserts the chump-policy CLI surfaces work end-to-end:
#   - `chump-policy check` exit codes (0=allowed, 1=blocked)
#   - `chump-policy set --scope X --enabled false` blocks subsequent check
#   - `chump-policy set --scope X --require-human-review true` blocks check
#   - `chump-policy set --scope X --trust-threshold N` + record-review loop
#     unlocks at N+1
#   - Most-restrictive precedence across 3 scopes
#
# Inline Rust tests (cargo test -p chump-policy --lib) cover the precedence
# algebra in isolation; this script covers the CLI binary + file storage
# integration the Rust tests can't reach.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# Build the binary first; subsequent calls re-use the artifact.
echo "[setup] cargo build -p chump-policy …"
PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH" cargo build -p chump-policy --bin chump-policy 2>&1 | tail -2

# Binary may land in worktree-local target/ OR workspace-shared target/.
# Probe both to handle the CARGO_TARGET_DIR / workspace-inheritance case.
BIN=""
for candidate in \
    "$REPO_ROOT/target/debug/chump-policy" \
    "$HOME/Projects/Chump/target/debug/chump-policy" \
    "$(PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH" cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["target_directory"])')/debug/chump-policy"; do
    if [[ -x "$candidate" ]]; then
        BIN="$candidate"
        break
    fi
done
if [[ -z "$BIN" ]]; then
    echo "[FAIL] chump-policy binary not found in any target dir"
    exit 1
fi

# Isolate every test in a fresh sandbox so the operator's real
# ~/.chump/auto_merge_policy.toml is not touched.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export CHUMP_REPO="$SANDBOX/repo"
mkdir -p "$HOME/.chump" "$CHUMP_REPO/.chump"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Test 1: default-permissive check returns 0 ─────────────────────────────
echo ""
echo "Test 1: empty policy files → check exits 0 (allowed)"
if "$BIN" check >/dev/null 2>&1; then
    pass "default check allowed"
else
    fail "default check blocked unexpectedly"
fi

# ── Test 2: --enabled false at any scope blocks ────────────────────────────
echo ""
echo "Test 2: scope=repo --enabled false → check exits 1"
"$BIN" set --scope repo --enabled false >/dev/null
if "$BIN" check >/dev/null 2>&1; then
    fail "expected block after --enabled false"
else
    pass "blocked as expected"
fi
# Reset: re-enable repo scope for subsequent tests.
"$BIN" set --scope repo --enabled true >/dev/null

# ── Test 3: --require-human-review blocks ──────────────────────────────────
echo ""
echo "Test 3: scope=operator --require-human-review true → check exits 1"
"$BIN" set --scope operator --require-human-review true >/dev/null
if "$BIN" check >/dev/null 2>&1; then
    fail "expected block after require_human_review"
else
    pass "blocked as expected"
fi
# Reset.
"$BIN" set --scope operator --require-human-review false >/dev/null

# ── Test 4: trust threshold ladder ─────────────────────────────────────────
echo ""
echo "Test 4: trust threshold=3 + record-review × 3 → check unlocks at 3"
"$BIN" set --scope operator --trust-threshold 3 >/dev/null
# Threshold > reviewed → should block.
if "$BIN" check >/dev/null 2>&1; then
    fail "trust=3 reviewed=0 should block"
else
    pass "trust=3 reviewed=0 blocked"
fi
# Increment twice → still blocked (reviewed=2, threshold=3).
"$BIN" record-review >/dev/null
"$BIN" record-review >/dev/null
if "$BIN" check >/dev/null 2>&1; then
    fail "trust=3 reviewed=2 should block"
else
    pass "trust=3 reviewed=2 blocked"
fi
# Third record-review → unlocks (reviewed=3, threshold=3).
"$BIN" record-review >/dev/null
if "$BIN" check >/dev/null 2>&1; then
    pass "trust=3 reviewed=3 allowed (threshold met)"
else
    fail "trust=3 reviewed=3 should allow"
fi

# ── Test 5: most-restrictive precedence ────────────────────────────────────
# Operator scope already has threshold=3 reviewed=3 (permissive). Add repo
# scope --require-human-review true. Expect check to block because repo
# overrides operator's permission.
echo ""
echo "Test 5: per-repo policy overrides per-operator (most-restrictive)"
"$BIN" set --scope repo --require-human-review true >/dev/null
if "$BIN" check >/dev/null 2>&1; then
    fail "repo --require-human-review should block even when operator allows"
else
    pass "repo most-restrictive wins"
fi

# ── Test 6: chump-policy show --json emits a parseable payload ─────────────
echo ""
echo "Test 6: show --json produces parseable JSON"
out=$("$BIN" show --json)
if python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert 'effective' in d and 'auto_merge_allowed' in d['effective']" "$out" 2>/dev/null; then
    pass "show --json parses"
else
    fail "show --json malformed: $out"
fi

# ── Test 7: check stdout contains an ambient-shape event line ──────────────
echo ""
echo "Test 7: check stdout includes auto_merge_policy_evaluated/_blocked kind"
# Re-enable everything for an allowed run.
"$BIN" set --scope repo --enabled true --require-human-review false >/dev/null
"$BIN" set --scope operator --enabled true --require-human-review false --trust-threshold 0 >/dev/null
allow_out=$("$BIN" check)
if echo "$allow_out" | grep -q '"kind":"auto_merge_policy_evaluated"'; then
    pass "allowed branch emits auto_merge_policy_evaluated"
else
    fail "allowed branch missing kind: $allow_out"
fi
# Now block + capture stdout (check exits 1 so guard the exit).
"$BIN" set --scope repo --enabled false >/dev/null
block_out=$("$BIN" check 2>&1 || true)
if echo "$block_out" | grep -q '"kind":"auto_merge_policy_blocked"'; then
    pass "blocked branch emits auto_merge_policy_blocked"
else
    fail "blocked branch missing kind: $block_out"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
