#!/usr/bin/env bash
# test-grep-c-echo0-guard.sh — CI smoke test for RESILIENT-281
#
# Verifies scripts/git-hooks/pre-commit-grep-c-echo0-guard.sh actually
# rejects the 'grep -c ... || echo 0' idiom in staged scripts/**.sh, and
# that a fixed file (using '|| true') passes. Proves the guard has teeth:
# this test must FAIL if the guard script is deleted or made a no-op.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GUARD="$REPO_ROOT/scripts/git-hooks/pre-commit-grep-c-echo0-guard.sh"
PASS=0
FAIL=0

_ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

echo "=== grep-c-echo0-guard smoke tests ==="

if [[ ! -x "$GUARD" ]]; then
    echo "FATAL: $GUARD not found or not executable" >&2
    exit 2
fi

TMPDIR_FIXTURE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

(
    cd "$TMPDIR_FIXTURE" || exit 1
    git init -q
    git config user.email test@test.local
    git config user.name test
    mkdir -p scripts
)

# Test 1: staged file WITH the idiom must make the guard exit non-zero.
mkdir -p "$TMPDIR_FIXTURE/scripts"
cat > "$TMPDIR_FIXTURE/scripts/bad.sh" <<'BAD'
#!/usr/bin/env bash
count=$(grep -c 'pattern' somefile 2>/dev/null || echo 0)
if [[ "$count" -gt 0 ]]; then
  echo "found"
fi
BAD

if (
    cd "$TMPDIR_FIXTURE" || exit 1
    git add scripts/bad.sh
    bash "$GUARD" >/tmp/grep-c-echo0-guard-test1.out 2>&1
); then
    _fail "guard should reject staged file with 'grep -c ... || echo 0' (exited 0)"
else
    if grep -q "grep -c-echo0-guard" /tmp/grep-c-echo0-guard-test1.out 2>/dev/null || \
       grep -q "grep-c-echo0-guard" /tmp/grep-c-echo0-guard-test1.out 2>/dev/null; then
        _ok "guard rejects idiom (exit non-zero, correct message)"
    else
        _fail "guard exited non-zero but message doesn't identify the check"
    fi
fi

# Test 2: same file fixed to use '|| true' must make the guard exit 0.
cat > "$TMPDIR_FIXTURE/scripts/bad.sh" <<'GOOD'
#!/usr/bin/env bash
count=$(grep -c 'pattern' somefile 2>/dev/null || true)
if [[ "$count" -gt 0 ]]; then
  echo "found"
fi
GOOD

if (
    cd "$TMPDIR_FIXTURE" || exit 1
    git add scripts/bad.sh
    bash "$GUARD" >/tmp/grep-c-echo0-guard-test2.out 2>&1
); then
    _ok "guard passes fixed file using '|| true'"
else
    _fail "guard should pass fixed file (exited non-zero): $(cat /tmp/grep-c-echo0-guard-test2.out)"
fi

# Test 3: bypass trailer allows the commit through.
cat > "$TMPDIR_FIXTURE/scripts/bad.sh" <<'BAD'
#!/usr/bin/env bash
count=$(grep -c 'pattern' somefile 2>/dev/null || echo 0)
BAD

if (
    cd "$TMPDIR_FIXTURE" || exit 1
    git add scripts/bad.sh
    mkdir -p .git
    printf 'test commit\n\nGrep-C-Echo0-Bypass: intentional test fixture\n' > .git/COMMIT_EDITMSG
    bash "$GUARD" >/tmp/grep-c-echo0-guard-test3.out 2>&1
); then
    _ok "bypass trailer allows commit through"
else
    _fail "bypass trailer should allow commit (exited non-zero): $(cat /tmp/grep-c-echo0-guard-test3.out)"
fi

# Test 4: no staged scripts/*.sh files -> guard is a no-op (exit 0).
if (
    cd "$TMPDIR_FIXTURE" || exit 1
    git rm --cached scripts/bad.sh -q 2>/dev/null || true
    echo "hi" > README.md
    git add README.md
    bash "$GUARD" >/tmp/grep-c-echo0-guard-test4.out 2>&1
); then
    _ok "guard no-ops when no scripts/*.sh staged"
else
    _fail "guard should no-op with no staged scripts/*.sh"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
