#!/usr/bin/env bash
# scripts/ci/test-dead-grep-detector.sh — CREDIBLE-332
#
# Verifies scripts/ci/dead-grep-detector.sh:
#   1. is executable and defaults to cwd when no repo-root arg is given
#   2. correctly resolves a plain repo-relative grep target that exists
#   3. flags a hardcoded grep target that does not exist (the CREDIBLE-237
#      vacuous-grep pattern: a CI gate pinned to "$REPO_ROOT/src/main.rs"
#      after the code it checks for moved out of main.rs — main.rs still
#      exists, but in the reduced fixture below it does not, reproducing
#      the same "grep target absent" shape without needing to check out
#      the real historical repo state)
#   4. reports a total count line

set -uo pipefail
PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/ci/dead-grep-detector.sh"

echo "=== CREDIBLE-332 dead-grep-detector tests ==="

echo ""
echo "--- 1. Script exists and is executable ---"
if [[ -x "$DETECTOR" ]]; then
    ok "dead-grep-detector.sh is executable"
else
    fail "dead-grep-detector.sh missing or not executable at $DETECTOR"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo ""
echo "--- 2. Real target resolves, no false positive ---"
mkdir -p "$TMP/live/scripts/ci" "$TMP/live/src"
echo 'fn main() {}' > "$TMP/live/src/present.rs"
cat > "$TMP/live/scripts/ci/test-real.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
grep -q "fn main" "$REPO_ROOT/src/present.rs"
EOF
out_live="$("$DETECTOR" "$TMP/live" 2>&1)"
if echo "$out_live" | grep -q "Total absent targets: 0"; then
    ok "existing target under \$REPO_ROOT reports zero absent targets"
else
    fail "existing target incorrectly flagged as absent: $out_live"
fi

echo ""
echo "--- 3. CREDIBLE-237 vacuous-grep pattern is identified ---"
mkdir -p "$TMP/vacuous/scripts/ci"
# Reduced fixture mirroring test-stale-binary-ship-blocked.sh's Test 2
# before the CREDIBLE-237 fix: grep target is a hardcoded path built
# from $REPO_ROOT that does not exist in this fixture (standing in for
# "the code moved out of this path").
cat > "$TMP/vacuous/scripts/ci/test-stale-binary-ship-blocked.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if ! grep -q "fail_if_stale_for_destructive" "$REPO_ROOT/src/main.rs"; then
    fail "src/main.rs does not call fail_if_stale_for_destructive"
fi
EOF
out_vacuous="$("$DETECTOR" "$TMP/vacuous" 2>&1)"
if echo "$out_vacuous" | grep -q "test-stale-binary-ship-blocked.sh"; then
    ok "flags the CREDIBLE-237 vacuous grep in test-stale-binary-ship-blocked.sh"
else
    fail "did not flag the known vacuous grep: $out_vacuous"
fi
if echo "$out_vacuous" | grep -qE "target=.*src/main\.rs"; then
    ok "reports the correct absent target (src/main.rs)"
else
    fail "did not report the expected target path: $out_vacuous"
fi

echo ""
echo "--- 4. Total count line present ---"
if echo "$out_vacuous" | grep -qE "^Total absent targets: [0-9]+$"; then
    ok "emits a total absent-target count"
else
    fail "missing total count line: $out_vacuous"
fi
if echo "$out_vacuous" | grep -q "Total absent targets: 1"; then
    ok "count is exactly 1 for the single-finding fixture"
else
    fail "unexpected count for single-finding fixture: $out_vacuous"
fi

echo ""
echo "--- 5. Defaults to cwd when repo-root arg omitted ---"
out_cwd="$(cd "$TMP/vacuous" && "$DETECTOR" 2>&1)"
if echo "$out_cwd" | grep -q "test-stale-binary-ship-blocked.sh"; then
    ok "defaults to current directory when no repo-root argument given"
else
    fail "did not default to cwd: $out_cwd"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
