#!/usr/bin/env bash
# INFRA-1223: meta-test — verify the lint gate test-no-direct-auto-merge-arm.sh
# correctly FAILS when a violator script is dropped into the tree, and PASSES
# once the violator is removed. Guards against regressions where someone
# inadvertently weakens the lint's regex.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LINT="${REPO_ROOT}/scripts/ci/test-no-direct-auto-merge-arm.sh"

if [[ ! -x "$LINT" ]]; then
    echo "[meta-test] FAIL: $LINT not executable" >&2
    exit 2
fi

# Place a violator under scripts/coord with an executable .sh extension and
# a clearly-not-allowlisted name so the lint can't accidentally skip it.
VIOLATOR="${REPO_ROOT}/scripts/coord/_infra1223_lint_fixture_violator.sh"

cleanup() {
    rm -f "$VIOLATOR"
}
trap cleanup EXIT

cat >"$VIOLATOR" <<'EOF'
#!/usr/bin/env bash
# A simulated bad caller — should be caught by the lint gate.
gh pr merge "$1" --auto --squash
EOF
chmod +x "$VIOLATOR"

# 1. With the violator present, the lint MUST fail.
set +e
"$LINT" >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    echo "[meta-test] FAIL: lint gate accepted a violator file at $VIOLATOR" >&2
    exit 1
fi
echo "[meta-test] PASS: lint correctly rejects fixture violator"

# 2. Remove the violator — lint MUST pass.
rm -f "$VIOLATOR"
trap - EXIT
if ! "$LINT" >/dev/null 2>&1; then
    echo "[meta-test] FAIL: lint gate rejects clean tree after violator removed" >&2
    "$LINT" 2>&1 | head -20 >&2
    exit 1
fi
echo "[meta-test] PASS: lint accepts clean tree after violator removed"

echo ""
echo "[meta-test] ALL META-TEST CHECKS PASSED — INFRA-1223 lint gate verified"
