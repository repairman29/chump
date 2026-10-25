#!/usr/bin/env bash
# scripts/ci/test-credible-1569-scoped-shell-gates.sh — CREDIBLE-1569 regression.
#
# Verifies:
#   1. Touching src/farmer_status.rs selects scripts/ci/test-fleet-kill-switch.sh,
#      scripts/ci/test-outcome-gate.sh, and scripts/ci/test-state-db-yaml-sync.sh.
#   2. Touching docs/ROADMAP.md selects zero shell tests.
#   3. In a stub git repo, a failing selected shell test blocks the push (exit != 0).
#   4. Mutant that drops the shell-test execution from pre-push fails this test.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

echo "=== CREDIBLE-1569: pre-push CI-scoped shell test selection ==="

# 1. src/farmer_status.rs selection on real repo ci.yml
sel="$(CHUMP_PREPUSH_SELECT_SHELL_TESTS_ONLY=1 CHUMP_PREPUSH_CHANGED_FILES="src/farmer_status.rs" bash "$HOOK" origin "" </dev/null 2>/dev/null)"
for expected in     "scripts/ci/test-fleet-kill-switch.sh"     "scripts/ci/test-outcome-gate.sh"     "scripts/ci/test-state-db-yaml-sync.sh"; do
    if grep -qxF "$expected" <<<"$sel"; then
        ok "src/farmer_status.rs selects $expected"
    else
        fail "src/farmer_status.rs did not select $expected (got: $sel)"
    fi
done

# 2. docs-only selection on real repo ci.yml -> none
docs_sel="$(CHUMP_PREPUSH_SELECT_SHELL_TESTS_ONLY=1 CHUMP_PREPUSH_CHANGED_FILES="docs/ROADMAP.md" bash "$HOOK" origin "" </dev/null 2>/dev/null)"
if [[ -z "$docs_sel" ]]; then
    ok "docs-only diff selects zero shell tests"
else
    fail "docs-only diff should select none, got: $docs_sel"
fi

# 3. Behavioral stub repo: failing selected shell test blocks push
T="$(mktemp -d "${TMPDIR:-/tmp}/credible-1569.XXXXXX")"
trap 'rm -rf "$T"' EXIT

git init -q -b main "$T/repo"
git -C "$T/repo" config user.email "test@example.com"
git -C "$T/repo" config user.name "Test"
mkdir -p "$T/repo/.github/workflows" "$T/repo/scripts/ci" "$T/repo/scripts/git-hooks" "$T/repo/src"
cp "$HOOK" "$T/repo/scripts/git-hooks/pre-push"
chmod +x "$T/repo/scripts/git-hooks/pre-push"

cat > "$T/repo/.github/workflows/ci.yml" <<'YML'
jobs:
  changes:
    steps:
      - uses: dorny/paths-filter@v3
        with:
          filters: |
            rust:
              - 'src/**'
  fast-checks:
    steps:
      - name: state-db-yaml-sync
        if: steps.changes.outputs.rust == 'true'
        run: bash scripts/ci/test-state-db-yaml-sync.sh
  fast-checks-heavy:
    steps:
      - name: fleet-kill-switch
        if: steps.changes.outputs.rust == 'true'
        run: bash scripts/ci/test-fleet-kill-switch.sh
  audit:
    strategy:
      matrix:
        include:
          - test_script: scripts/ci/test-outcome-gate.sh
YML

cat > "$T/repo/scripts/ci/test-state-db-yaml-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$T/repo/scripts/ci/test-fleet-kill-switch.sh" <<'SH'
#!/usr/bin/env bash
# references farmer_status.rs
echo "simulated failure in test-fleet-kill-switch.sh" >&2
exit 1
SH
cat > "$T/repo/scripts/ci/test-outcome-gate.sh" <<'SH'
#!/usr/bin/env bash
# references farmer_status.rs
exit 0
SH
chmod +x "$T/repo/scripts/ci/"*.sh

echo "pub fn x() {}" > "$T/repo/src/farmer_status.rs"
git -C "$T/repo" add .
git -C "$T/repo" commit -q -m "init"
git clone -q --bare "$T/repo" "$T/origin.git"
git -C "$T/repo" remote add origin "$T/origin.git"
git -C "$T/repo" fetch -q origin main
base_sha="$(git -C "$T/repo" rev-parse HEAD)"

git -C "$T/repo" checkout -q -b fix/CREDIBLE-1569-test
echo "pub fn y() {}" >> "$T/repo/src/farmer_status.rs"
git -C "$T/repo" add src/farmer_status.rs
git -C "$T/repo" commit -q -m "touch farmer_status"
head_sha="$(git -C "$T/repo" rev-parse HEAD)"

mkdir -p "$T/bin"
cat > "$T/bin/cargo" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$T/bin/cargo-nextest" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$T/bin/cargo" "$T/bin/cargo-nextest"

run_stub_push() {
    local hook_to_run="$1"
    rm -rf "$T/repo/.chump-locks/test-gate-cache"
    local rc=0
    (
        cd "$T/repo" &&         PATH="$T/bin:/usr/bin:/bin"         CHUMP_CLIPPY_GATE=0         bash "$hook_to_run" origin "$T/origin.git"             <<< "refs/heads/fix/CREDIBLE-1569-test $head_sha refs/heads/fix/CREDIBLE-1569-test $base_sha"
    ) >"$T/push.out" 2>&1 || rc=$?
    echo "$rc"
}

rc="$(run_stub_push "$T/repo/scripts/git-hooks/pre-push")"
if [[ "$rc" -ne 0 ]] && grep -q "BLOCKED (CREDIBLE-1569): CI-scoped shell test failed: scripts/ci/test-fleet-kill-switch.sh" "$T/push.out"; then
    ok "failing CI-scoped shell test (test-fleet-kill-switch.sh) blocks push in stub repo"
else
    fail "expected failing CI-scoped shell test to block push (rc=$rc): $(cat "$T/push.out")"
fi

# 4. Mutant check: drop shell-test execution from pre-push
python3 - "$T/repo/scripts/git-hooks/pre-push" <<'PY'
import sys
src = open(sys.argv[1]).read()
mut = src.replace('_SCOPED_SHELL_TESTS="$(prepush_select_shell_tests', '_SCOPED_SHELL_TESTS="" #')
assert mut != src
open(sys.argv[1], "w").write(mut)
PY
chmod +x "$T/repo/scripts/git-hooks/pre-push"
mut_rc="$(run_stub_push "$T/repo/scripts/git-hooks/pre-push")"
if [[ "$mut_rc" -eq 0 ]]; then
    ok "mutant (dropping shell-test selection from pre-push) is killed (push would have succeeded)"
else
    fail "mutant did not change push outcome (mut_rc=$mut_rc)"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
