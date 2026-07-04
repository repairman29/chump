#!/usr/bin/env bash
# scripts/ci/test-css-token-discipline.sh — INFRA-1590
#
# Smoke test for the CSS token discipline linter.
# Runs scripts/lint/css-token-discipline.sh against clean and dirty fixtures
# and asserts the expected exit codes.
#
# Usage: bash scripts/ci/test-css-token-discipline.sh
# Exit: 0 = all assertions passed; non-zero = failure.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LINTER="$REPO_ROOT/scripts/lint/css-token-discipline.sh"
CLEAN_FIXTURE="$REPO_ROOT/tests/fixtures/css-token-clean.html"
DIRTY_FIXTURE="$REPO_ROOT/tests/fixtures/css-token-violation.html"

PASS=0
FAIL=0
ERRORS=()

# Helper: assert linter exits with expected code for a staged fixture
# Usage: _assert_exit <fixture_path> <expected_exit> <test_name>
_assert_exit() {
    local fixture="$1"
    local expected="$2"
    local name="$3"

    if [[ ! -f "$fixture" ]]; then
        ERRORS+=("SKIP $name: fixture not found: $fixture")
        return
    fi
    if [[ ! -x "$LINTER" ]]; then
        ERRORS+=("SKIP $name: linter not executable: $LINTER")
        return
    fi

    # Stage the fixture in a temp git index so we can test the real hook path.
    local tmpdir
    tmpdir="$(mktemp -d)"
    local tmpgit="$tmpdir/repo"
    git init -q "$tmpgit"
    mkdir -p "$tmpgit/web/fixtures"
    cp "$fixture" "$tmpgit/web/fixtures/test.html"
    git -C "$tmpgit" add web/fixtures/test.html 2>/dev/null

    # Run the linter with the temp repo as root.
    # Override REPO_ROOT so the linter resolves its paths correctly.
    local actual_exit=0
    CHUMP_CSS_TOKEN_CHECK=1 \
    GIT_DIR="$tmpgit/.git" \
    GIT_WORK_TREE="$tmpgit" \
        bash "$LINTER" 2>/dev/null || actual_exit=$?

    rm -rf "$tmpdir"

    if [[ "$actual_exit" == "$expected" || \
          ( "$expected" != "0" && "$actual_exit" != "0" ) ]]; then
        echo "  PASS  $name (exit=$actual_exit, expected=$expected)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name (exit=$actual_exit, expected=$expected)"
        ERRORS+=("FAIL $name: exit=$actual_exit, expected=$expected")
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== CSS token discipline smoke test (INFRA-1590) ==="
echo ""

# ── Test: clean fixture passes ────────────────────────────────────────────────
echo "-- clean fixture --"

# The clean fixture doesn't have an index.html in web/v2/, so Rule 3 won't
# fire (no :root to compare against). Rules 1, 2, and 4 are the active gates.
_assert_exit "$CLEAN_FIXTURE" 0 "clean fixture exits 0"

# ── Test: dirty fixture fails ─────────────────────────────────────────────────
echo ""
echo "-- dirty fixture --"
_assert_exit "$DIRTY_FIXTURE" 1 "dirty fixture exits non-zero"

# ── Test: env bypass disables the gate ───────────────────────────────────────
echo ""
echo "-- env bypass (CHUMP_CSS_TOKEN_CHECK=0) --"
(
    export CHUMP_CSS_TOKEN_CHECK=0
    # Stage the dirty fixture in a minimal repo
    tmpdir2="$(mktemp -d)"
    git init -q "$tmpdir2/r"
    mkdir -p "$tmpdir2/r/web/fixtures"
    cp "$DIRTY_FIXTURE" "$tmpdir2/r/web/fixtures/test.html"
    git -C "$tmpdir2/r" add web/fixtures/test.html 2>/dev/null
    exit_code=0
    GIT_DIR="$tmpdir2/r/.git" GIT_WORK_TREE="$tmpdir2/r" bash "$LINTER" 2>/dev/null || exit_code=$?
    rm -rf "$tmpdir2"
    if [[ "$exit_code" == "0" ]]; then
        echo "  PASS  env bypass exits 0"
        exit 0
    else
        echo "  FAIL  env bypass should exit 0, got $exit_code"
        exit 1
    fi
) && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); ERRORS+=("FAIL env bypass"); }

# ── Test: linter script is executable ────────────────────────────────────────
echo ""
echo "-- linter metadata --"
if [[ -x "$LINTER" ]]; then
    echo "  PASS  linter is executable"
    PASS=$((PASS + 1))
else
    echo "  FAIL  linter is not executable: $LINTER"
    ERRORS+=("FAIL linter not executable")
    FAIL=$((FAIL + 1))
fi

# ── Test: baseline file exists ────────────────────────────────────────────────
BASELINE="$REPO_ROOT/.css-discipline-baseline.txt"
if [[ -f "$BASELINE" ]]; then
    echo "  PASS  baseline file exists"
    PASS=$((PASS + 1))
else
    echo "  FAIL  baseline file missing: $BASELINE"
    ERRORS+=("FAIL baseline missing")
    FAIL=$((FAIL + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if (( FAIL > 0 )); then
    for e in "${ERRORS[@]}"; do
        echo "  ERROR: $e" >&2
    done
    exit 1
fi

exit 0
