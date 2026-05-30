#!/usr/bin/env bash
# scripts/ci/test-rotate-sccache-r2-gh-only.sh — INFRA-2240 smoke
#
# Tests the gh-only rotation script's parse + validation + dry-run paths.
# Does NOT make real gh API calls — uses fake input files + --dry-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROT="$REPO_ROOT/scripts/ops/rotate-sccache-r2-gh-only.sh"

PASS=0
FAIL=0
_pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
_fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== test-rotate-sccache-r2-gh-only.sh (INFRA-2240) ==="

# ── Test 1: bash -n syntax ──────────────────────────────────────────────────
if bash -n "$ROT" 2>&1; then
    _pass "syntax: rotate-sccache-r2-gh-only.sh passes bash -n"
else
    _fail "syntax: rotate-sccache-r2-gh-only.sh has bash syntax errors"
fi

# ── Test 2: --help exits 0 + shows usage ────────────────────────────────────
if bash "$ROT" --help 2>&1 | grep -qE "Atomic update|PRIMARY rotation path"; then
    _pass "help: --help prints docstring"
else
    _fail "help: --help did not print expected docstring"
fi

# ── Test 3: --bogus-flag rejected ───────────────────────────────────────────
out="$(bash "$ROT" --bogus-flag 2>&1 || true)"
if echo "$out" | grep -q "unknown flag"; then
    _pass "args: --bogus-flag rejected with 'unknown flag' message"
else
    _fail "args: --bogus-flag did NOT produce unknown-flag error"
fi

# ── Test 4: missing input file rejected with helpful message ────────────────
out="$(bash "$ROT" --input-file /tmp/does-not-exist-INFRA-2240.txt 2>&1 || true)"
if echo "$out" | grep -q "input file not found"; then
    _pass "validation: missing input file produces expected error + creation hint"
else
    _fail "validation: missing input file did NOT produce expected error"
fi

# ── Test 5: wrong-length ACCESS_KEY_ID refused ──────────────────────────────
TMP="$(mktemp -t r2-test-XXXX.txt)"
cat > "$TMP" <<EOF
ACCESS_KEY_ID=tooshort
SECRET_ACCESS_KEY=6256b35f54f24751a1c7d0e7ff43e1b7ab12764cea7597ffa3fdfae9f3561abf
EOF
out="$(bash "$ROT" --input-file "$TMP" 2>&1 || true)"
if echo "$out" | grep -q "ACCESS_KEY_ID length.*expected 32"; then
    _pass "validation: wrong-length ACCESS_KEY_ID refused"
else
    _fail "validation: wrong-length ACCESS_KEY_ID NOT refused"
fi
rm -f "$TMP"

# ── Test 6: wrong-length SECRET_ACCESS_KEY refused ──────────────────────────
TMP="$(mktemp -t r2-test-XXXX.txt)"
cat > "$TMP" <<EOF
ACCESS_KEY_ID=6b7d5de8c91c4d7e9f1e10ccec056c81
SECRET_ACCESS_KEY=tooshort
EOF
out="$(bash "$ROT" --input-file "$TMP" 2>&1 || true)"
if echo "$out" | grep -q "SECRET_ACCESS_KEY length.*expected 64"; then
    _pass "validation: wrong-length SECRET_ACCESS_KEY refused"
else
    _fail "validation: wrong-length SECRET_ACCESS_KEY NOT refused"
fi
rm -f "$TMP"

# ── Test 7: missing key refused ─────────────────────────────────────────────
TMP="$(mktemp -t r2-test-XXXX.txt)"
cat > "$TMP" <<EOF
SECRET_ACCESS_KEY=6256b35f54f24751a1c7d0e7ff43e1b7ab12764cea7597ffa3fdfae9f3561abf
EOF
out="$(bash "$ROT" --input-file "$TMP" 2>&1 || true)"
if echo "$out" | grep -q "ACCESS_KEY_ID not found"; then
    _pass "validation: missing ACCESS_KEY_ID key refused"
else
    _fail "validation: missing ACCESS_KEY_ID key NOT refused"
fi
rm -f "$TMP"

# ── Test 8: dry-run with valid input ─────────────────────────────────────────
TMP="$(mktemp -t r2-test-XXXX.txt)"
cat > "$TMP" <<EOF
# this is a comment
ACCESS_KEY_ID=6b7d5de8c91c4d7e9f1e10ccec056c81

SECRET_ACCESS_KEY=6256b35f54f24751a1c7d0e7ff43e1b7ab12764cea7597ffa3fdfae9f3561abf
EOF
out="$(bash "$ROT" --input-file "$TMP" 2>&1 || true)"
if echo "$out" | grep -q "dry-run complete"; then
    _pass "dry-run: valid input parses + reaches dry-run-complete (no side effects)"
else
    _fail "dry-run: valid input did NOT complete dry-run cleanly"
    echo "$out" | head -10 >&2
fi

# Confirm dry-run did NOT delete the input file
[[ -f "$TMP" ]] && _pass "dry-run: input file preserved (not deleted)" || _fail "dry-run: input file was deleted (should not happen on dry-run)"
rm -f "$TMP"

# ── Test 9: fingerprint never echoes full secret ────────────────────────────
TMP="$(mktemp -t r2-test-XXXX.txt)"
cat > "$TMP" <<EOF
ACCESS_KEY_ID=6b7d5de8c91c4d7e9f1e10ccec056c81
SECRET_ACCESS_KEY=6256b35f54f24751a1c7d0e7ff43e1b7ab12764cea7597ffa3fdfae9f3561abf
EOF
out="$(bash "$ROT" --input-file "$TMP" 2>&1 || true)"
if echo "$out" | grep -qE "6b7d5de8c91c4d7e9f1e10ccec056c81|6256b35f54f24751a1c7d0e7ff43e1b7ab12764cea7597ffa3fdfae9f3561abf"; then
    _fail "audit: full secret value appeared in dry-run output (security bug)"
else
    _pass "audit: dry-run output does NOT contain full secret values"
fi
if echo "$out" | grep -q "6b7d...6c81"; then
    _pass "audit: dry-run output uses first-4...last-4 fingerprint pattern"
else
    _fail "audit: dry-run output missing fingerprint pattern"
fi
rm -f "$TMP"

# ── Test 10: default is dry-run (no --execute → no side effects) ────────────
if grep -q '^EXECUTE=0$' "$ROT"; then
    _pass "default: EXECUTE defaults to 0 (dry-run); --execute required to rotate"
else
    _fail "default: EXECUTE does NOT default to 0"
fi

# ── Test 11: ambient kinds present in source ────────────────────────────────
if grep -q "sccache_r2_gh_rotated" "$ROT" \
   && grep -q "sccache_r2_gh_rotation_failed" "$ROT" \
   && grep -q "sccache_r2_gh_rotation_partial" "$ROT"; then
    _pass "ambient: emits sccache_r2_gh_rotated + _failed + _partial kinds"
else
    _fail "ambient: missing one or more expected ambient kinds"
fi

# ── Test 12: INFRA-2240 attribution ─────────────────────────────────────────
if grep -q "INFRA-2240" "$ROT"; then
    _pass "doc: INFRA-2240 attribution present in script header"
else
    _fail "doc: INFRA-2240 attribution missing"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
