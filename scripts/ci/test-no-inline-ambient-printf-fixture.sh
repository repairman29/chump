#!/usr/bin/env bash
# INFRA-1307: meta-test — verify the lint correctly detects net-new
# inline-emit files (printf … >> ambient.jsonl).

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LINT="${REPO_ROOT}/scripts/ci/test-no-inline-ambient-printf.sh"

if [[ ! -x "$LINT" ]]; then
    echo "[meta-test] FAIL: $LINT not executable" >&2
    exit 2
fi

VIOLATOR="${REPO_ROOT}/scripts/coord/_infra1307_inline_violator.sh"
CLEAN="${REPO_ROOT}/scripts/coord/_infra1307_no_emit_addition.sh"
ORIG_REF="$(git rev-parse HEAD)"
ORIG_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"

cleanup() {
    git reset --hard "$ORIG_REF" 2>/dev/null || true
    rm -f "$VIOLATOR" "$CLEAN"
    if [[ -n "$ORIG_BRANCH" ]]; then
        git symbolic-ref HEAD "refs/heads/$ORIG_BRANCH" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Case 1: new file with inline emit (should FAIL).
cat >"$VIOLATOR" <<'EOF'
#!/usr/bin/env bash
LOCK_DIR=".chump-locks"
printf '{"ts":"%s","kind":"_fixture_kind","x":"y"}\n' "$(date -u +%s)" >> "$LOCK_DIR/ambient.jsonl"
EOF
chmod +x "$VIOLATOR"

# Case 2: new file with no ambient writes (should PASS).
cat >"$CLEAN" <<'EOF'
#!/usr/bin/env bash
echo "no ambient writes here, just informational"
EOF
chmod +x "$CLEAN"

git add "$VIOLATOR" "$CLEAN" 2>/dev/null
git -c user.email=infra1307@test -c user.name="meta-test" \
    commit -m "fixture: inline-emit violator + clean control" --no-verify >/dev/null 2>&1

# 1. Strict mode rejects the inline-emit violator.
set +e
CHUMP_NEW_AMBIENT_PRINTF_MODE=strict BASE_REF="$ORIG_REF" "$LINT" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[meta-test] FAIL: lint (strict) accepted a net-new inline-emit file" >&2
    exit 1
fi
echo "[meta-test] PASS: lint correctly rejects fixture violator (strict)"

# 2. The clean control should NOT be flagged.
OUT="$(CHUMP_NEW_AMBIENT_PRINTF_MODE=strict BASE_REF="$ORIG_REF" "$LINT" 2>&1 || true)"
if echo "$OUT" | grep -q "_infra1307_no_emit_addition.sh"; then
    echo "[meta-test] FAIL: clean control was incorrectly flagged" >&2
    echo "$OUT" >&2
    exit 1
fi
echo "[meta-test] PASS: clean control NOT flagged"

# 3. Warn mode exits 0 despite violation.
set +e
CHUMP_NEW_AMBIENT_PRINTF_MODE=warn BASE_REF="$ORIG_REF" "$LINT" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[meta-test] FAIL: lint (warn) failed; expected exit 0" >&2
    exit 1
fi
echo "[meta-test] PASS: warn mode exits 0 despite violation"

# 4. Allowlist entry exempts the violator.
TMP_AL=$(mktemp)
cp "${REPO_ROOT}/scripts/ci/ambient-emit-allowlist.txt" "$TMP_AL"
echo "scripts/coord/_infra1307_inline_violator.sh  # reason: meta-test fixture" \
    >> "${REPO_ROOT}/scripts/ci/ambient-emit-allowlist.txt"
set +e
CHUMP_NEW_AMBIENT_PRINTF_MODE=strict BASE_REF="$ORIG_REF" "$LINT" >/dev/null 2>&1
rc=$?
set -e
cp "$TMP_AL" "${REPO_ROOT}/scripts/ci/ambient-emit-allowlist.txt"
rm -f "$TMP_AL"
if [[ $rc -ne 0 ]]; then
    echo "[meta-test] FAIL: allowlist entry did not exempt the violator" >&2
    exit 1
fi
echo "[meta-test] PASS: allowlist entry exempts violator"

echo ""
echo "[meta-test] ALL META-TEST CHECKS PASSED — INFRA-1307 gate verified"
