#!/usr/bin/env bash
# INFRA-1305: meta-test — verify the lint correctly detects net-new
# scripts/coord/*.sh files. Mirrors INFRA-1223's fixture pattern.

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LINT="${REPO_ROOT}/scripts/ci/test-no-new-coord-shell.sh"

if [[ ! -x "$LINT" ]]; then
    echo "[meta-test] FAIL: $LINT not executable" >&2
    exit 2
fi

# Simulate a "PR adds new file" condition by committing a violator on a
# throwaway branch, then running the lint with BASE_REF pointing at the
# pre-violator commit. This is what CI does: base = origin/main, head =
# the PR's tip; diff-filter=A returns files added.
VIOLATOR="${REPO_ROOT}/scripts/coord/_infra1305_fixture_violator.sh"
ORIG_REF="$(git rev-parse HEAD)"
TMP_BRANCH="_infra1305_fixture_branch_$$"
ORIG_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"

cleanup() {
    # Hard-reset to the pre-fixture HEAD (drops the fixture commit + its
    # index entry). Then nuke any residual file on disk.
    git reset --hard "$ORIG_REF" 2>/dev/null || true
    rm -f "$VIOLATOR"
    if [[ -n "$ORIG_BRANCH" ]]; then
        git symbolic-ref HEAD "refs/heads/$ORIG_BRANCH" 2>/dev/null || true
    fi
    git branch -D "$TMP_BRANCH" 2>/dev/null || true
}
trap cleanup EXIT

cat >"$VIOLATOR" <<'EOF'
#!/usr/bin/env bash
# A simulated new coord shell — should be caught by INFRA-1305.
echo "fake fleet-coordination script"
EOF
chmod +x "$VIOLATOR"
git add "$VIOLATOR" 2>/dev/null
git -c user.email=infra1305@test -c user.name="meta-test" \
    commit -m "fixture: add coord shell violator" --no-verify >/dev/null 2>&1

# 1. Strict mode rejects the new file (base = pre-fixture commit).
set +e
CHUMP_NEW_COORD_SHELL_MODE=strict BASE_REF="$ORIG_REF" "$LINT" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[meta-test] FAIL: lint (strict) accepted a net-new coord shell" >&2
    exit 1
fi
echo "[meta-test] PASS: lint correctly rejects fixture violator (strict)"

# 2. Warn mode prints but does NOT fail.
set +e
CHUMP_NEW_COORD_SHELL_MODE=warn BASE_REF="$ORIG_REF" "$LINT" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    echo "[meta-test] FAIL: lint (warn) failed; expected exit 0" >&2
    exit 1
fi
echo "[meta-test] PASS: warn mode exits 0 despite violation"

# 3. Allowlist entry → strict passes even with violator present.
TMP_AL=$(mktemp)
cp "${REPO_ROOT}/scripts/ci/coord-shell-allowlist.txt" "$TMP_AL"
echo "scripts/coord/_infra1305_fixture_violator.sh  # reason: meta-test fixture" \
    >> "${REPO_ROOT}/scripts/ci/coord-shell-allowlist.txt"
set +e
CHUMP_NEW_COORD_SHELL_MODE=strict BASE_REF="$ORIG_REF" "$LINT" >/dev/null 2>&1
rc=$?
set -e
cp "$TMP_AL" "${REPO_ROOT}/scripts/ci/coord-shell-allowlist.txt"
rm -f "$TMP_AL"
if [[ $rc -ne 0 ]]; then
    echo "[meta-test] FAIL: allowlist entry did not exempt the violator" >&2
    exit 1
fi
echo "[meta-test] PASS: allowlist entry exempts violator"

echo ""
echo "[meta-test] ALL META-TEST CHECKS PASSED — INFRA-1305 gate verified"
