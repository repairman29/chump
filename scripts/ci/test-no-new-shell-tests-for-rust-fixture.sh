#!/usr/bin/env bash
# INFRA-1306: meta-test — verify the lint correctly detects net-new
# `scripts/ci/test-*.sh` files that exercise Rust-backed chump logic.

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LINT="${REPO_ROOT}/scripts/ci/test-no-new-shell-tests-for-rust.sh"

if [[ ! -x "$LINT" ]]; then
    echo "[meta-test] FAIL: $LINT not executable" >&2
    exit 2
fi

VIOLATOR="${REPO_ROOT}/scripts/ci/test-_infra1306_fixture_violator.sh"
PURE="${REPO_ROOT}/scripts/ci/test-_infra1306_fixture_pure_shell.sh"
ORIG_REF="$(git rev-parse HEAD)"
ORIG_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"

cleanup() {
    git reset --hard "$ORIG_REF" 2>/dev/null || true
    rm -f "$VIOLATOR" "$PURE"
    if [[ -n "$ORIG_BRANCH" ]]; then
        git symbolic-ref HEAD "refs/heads/$ORIG_BRANCH" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Case 1: Rust-backed shell test (should FAIL) ──
cat >"$VIOLATOR" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
BIN="${CHUMP_BIN:-target/debug/chump}"
"$BIN" --web --port 38999 &
sleep 1
curl -sf http://localhost:38999/api/health
kill %1
EOF
chmod +x "$VIOLATOR"

# ── Case 2: pure shell test (no chump invocation, should PASS) ──
cat >"$PURE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Tests git-hook behaviour without invoking chump
test -x scripts/git-hooks/pre-commit
EOF
chmod +x "$PURE"

git add "$VIOLATOR" "$PURE" 2>/dev/null
git -c user.email=infra1306@test -c user.name="meta-test" \
    commit -m "fixture: add Rust-backed + pure shell tests" --no-verify >/dev/null 2>&1

# 1. Strict mode rejects the Rust-backed test.
set +e
CHUMP_NEW_SHELL_TEST_MODE=strict BASE_REF="$ORIG_REF" "$LINT" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[meta-test] FAIL: lint (strict) accepted a Rust-backed shell test" >&2
    exit 1
fi
echo "[meta-test] PASS: lint correctly rejects Rust-backed shell test"

# 2. The pure-shell fixture should NOT have been flagged (it doesn't
#    invoke chump). Verify by checking that the lint mentions exactly
#    the violator path, not the pure one.
OUT="$(CHUMP_NEW_SHELL_TEST_MODE=strict BASE_REF="$ORIG_REF" "$LINT" 2>&1 || true)"
if echo "$OUT" | grep -q "test-_infra1306_fixture_pure_shell.sh"; then
    echo "[meta-test] FAIL: pure-shell fixture was incorrectly flagged" >&2
    echo "$OUT" >&2
    exit 1
fi
echo "[meta-test] PASS: pure-shell test NOT flagged (heuristic correct)"

# 3. Warn mode prints but doesn't fail.
set +e
CHUMP_NEW_SHELL_TEST_MODE=warn BASE_REF="$ORIG_REF" "$LINT" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[meta-test] FAIL: lint (warn) failed; expected exit 0" >&2
    exit 1
fi
echo "[meta-test] PASS: warn mode exits 0 despite violation"

# 4. Allowlist entry exempts the violator.
TMP_AL=$(mktemp)
cp "${REPO_ROOT}/scripts/ci/shell-test-allowlist.txt" "$TMP_AL"
echo "scripts/ci/test-_infra1306_fixture_violator.sh  # reason: meta-test fixture" \
    >> "${REPO_ROOT}/scripts/ci/shell-test-allowlist.txt"
set +e
CHUMP_NEW_SHELL_TEST_MODE=strict BASE_REF="$ORIG_REF" "$LINT" >/dev/null 2>&1
rc=$?
set -e
cp "$TMP_AL" "${REPO_ROOT}/scripts/ci/shell-test-allowlist.txt"
rm -f "$TMP_AL"
if [[ $rc -ne 0 ]]; then
    echo "[meta-test] FAIL: allowlist entry did not exempt the violator" >&2
    exit 1
fi
echo "[meta-test] PASS: allowlist entry exempts violator"

echo ""
echo "[meta-test] ALL META-TEST CHECKS PASSED — INFRA-1306 gate verified"
