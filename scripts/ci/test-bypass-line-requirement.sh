#!/usr/bin/env bash
# test-bypass-line-requirement.sh — INFRA-5429: fixture tests for
# check-bypass-line-presence.sh (the audit that enforces every CI gate's
# FAIL path prints a "How to bypass cleanly: <instructions>" line).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIT="$SCRIPT_DIR/check-bypass-line-presence.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-bypass-line.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Test 1: a failing check with NO bypass line — audit must FAIL clearly ──
NO_BYPASS="$TMP/check-no-bypass.sh"
cat > "$NO_BYPASS" <<'EOF'
#!/usr/bin/env bash
echo "[FAIL] something is wrong" >&2
exit 1
EOF
chmod +x "$NO_BYPASS"

if out="$(bash "$AUDIT" "$NO_BYPASS" 2>&1)"; then
    rc=0
else
    rc=$?
fi
[[ "$rc" -ne 0 ]] || fail "Test 1: audit should exit non-zero for a check missing a bypass line"
echo "$out" | grep -q "missing a 'How to bypass cleanly:' line" \
    || fail "Test 1: audit output should clearly name the missing-bypass-line failure: $out"
echo "$out" | grep -qF "check-no-bypass.sh" \
    || fail "Test 1: audit output should name the offending file: $out"
pass "Test 1: check without a bypass line fails the audit with a clear message"

# ── Test 2: a failing check WITH a bypass line — audit passes ──────────────
WITH_BYPASS="$TMP/check-with-bypass.sh"
cat > "$WITH_BYPASS" <<'EOF'
#!/usr/bin/env bash
echo "[FAIL] something is wrong" >&2
echo "How to bypass cleanly: set CHUMP_FAKE_CHECK=0 to skip this gate." >&2
exit 1
EOF
chmod +x "$WITH_BYPASS"

if bash "$AUDIT" "$WITH_BYPASS" > /dev/null 2>&1; then
    pass "Test 2: check with a bypass line passes the audit"
else
    fail "Test 2: audit should pass a check that documents its bypass"
fi

# ── Test 3: a check with no exit-1 FAIL path at all — audit passes (N/A) ───
NEVER_FAILS="$TMP/check-never-fails.sh"
cat > "$NEVER_FAILS" <<'EOF'
#!/usr/bin/env bash
echo "always OK"
exit 0
EOF
chmod +x "$NEVER_FAILS"

if bash "$AUDIT" "$NEVER_FAILS" > /dev/null 2>&1; then
    pass "Test 3: check with no exit-1 path is not flagged"
else
    fail "Test 3: a check that never fails should not require a bypass line"
fi

# ── Test 4: exceptions file suppresses the requirement ─────────────────────
EXC_DIR="$TMP/exc"
mkdir -p "$EXC_DIR"
cp "$NO_BYPASS" "$EXC_DIR/check-excepted.sh"
printf 'check-excepted.sh   # reason: test fixture, no bypass applicable\n' > "$EXC_DIR/bypass-line-exceptions.txt"
# check-bypass-line-presence.sh looks for its exceptions file next to itself,
# so exercise it by running an audit copy colocated with a matching exceptions file.
cp "$AUDIT" "$EXC_DIR/check-bypass-line-presence.sh"
if bash "$EXC_DIR/check-bypass-line-presence.sh" "$EXC_DIR/check-excepted.sh" > /dev/null 2>&1; then
    pass "Test 4: allowlisted script is exempt from the bypass-line requirement"
else
    fail "Test 4: allowlisted script should not be flagged"
fi

# ── Test 5: dogfood — the real scripts/ci/check-*.sh tree passes today ─────
if bash "$AUDIT" > /dev/null 2>&1; then
    pass "Test 5: current scripts/ci/check-*.sh tree passes the bypass-line audit"
else
    fail "Test 5: real check-*.sh tree should pass — run 'bash $AUDIT' to see which script regressed"
fi

echo ""
echo "All INFRA-5429 bypass-line-requirement checks passed."
