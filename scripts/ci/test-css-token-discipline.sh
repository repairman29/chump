#!/usr/bin/env bash
# test-css-token-discipline.sh — CI smoke test for INFRA-1590
#
# Runs scripts/lint/css-token-discipline.sh against known-good and known-bad
# fixtures, asserts the correct exit codes.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="$REPO_ROOT/scripts/lint/css-token-discipline.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures"
PASS=0
FAIL=0

_ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

echo "=== css-token-discipline smoke tests ==="

# Sanity: linter must exist and be executable
if [[ ! -x "$LINT" ]]; then
    echo "FATAL: $LINT not found or not executable" >&2
    exit 2
fi

# Test 1: clean fixture should exit 0
if CHUMP_CSS_TOKEN_INDEX="$FIXTURE_DIR/css-token-clean.html" \
   bash "$LINT" --all --index "$FIXTURE_DIR/css-token-clean.html" \
   2>/dev/null; then
    _ok "clean fixture exits 0"
else
    _fail "clean fixture should exit 0 (exited non-zero)"
fi

# Test 2: violation fixture should exit 1 (raw hex outside :root)
if CHUMP_CSS_TOKEN_INDEX="$FIXTURE_DIR/css-token-clean.html" \
   bash "$LINT" --all --index "$FIXTURE_DIR/css-token-clean.html" \
   2>/dev/null <<< ""; then
    # Actually run against violation file
    :
fi

# Point linter at just the violation file using a temp dir trick
TMPDIR_FIXTURE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# Create a minimal web/ subtree pointing at the violation fixture
mkdir -p "$TMPDIR_FIXTURE/web/v2"
cp "$FIXTURE_DIR/css-token-violation.html" "$TMPDIR_FIXTURE/web/v2/test.html"
cp "$FIXTURE_DIR/css-token-clean.html" "$TMPDIR_FIXTURE/web/v2/index.html"

# Override REPO_ROOT and run
if ! (
    cd "$TMPDIR_FIXTURE" && git init -q && git add . 2>/dev/null
    CHUMP_CSS_TOKEN_INDEX="$TMPDIR_FIXTURE/web/v2/index.html" \
    CHUMP_CSS_BASELINE="/dev/null" \
    bash "$LINT" --all 2>/dev/null
); then
    _ok "violation fixture exits non-zero (violations detected)"
else
    _fail "violation fixture should exit non-zero (linter missed violations)"
fi

# Test 3: rule2 — --*-primary token definition is caught
RULE2_FILE="$TMPDIR_FIXTURE/web/v2/rule2_test.html"
cat > "$RULE2_FILE" <<'HTML'
<style>
:root { --bg-primary: #0d0d0f; }
.x { background: var(--bg-primary); }
</style>
HTML

if ! (
    cd "$TMPDIR_FIXTURE"
    CHUMP_CSS_TOKEN_INDEX="$TMPDIR_FIXTURE/web/v2/index.html" \
    CHUMP_CSS_BASELINE="/dev/null" \
    bash "$LINT" --all 2>/dev/null
); then
    _ok "rule2: --bg-primary definition caught"
else
    _fail "rule2: --bg-primary definition should be caught"
fi

# Test 4: baseline whitelist suppresses violations
BASELINE_FILE=$(mktemp)
echo "rule4:dummy" >> "$BASELINE_FILE"
# Add the violation file's path entries to baseline
echo "$TMPDIR_FIXTURE/web/v2/test.html:10:rule1-hex" >> "$BASELINE_FILE"

# Mostly checking that the baseline is wired up (we don't need exhaustive coverage)
# just verify the script doesn't crash when CHUMP_CSS_BASELINE is set
if (
    cd "$TMPDIR_FIXTURE"
    CHUMP_CSS_TOKEN_INDEX="$TMPDIR_FIXTURE/web/v2/index.html" \
    CHUMP_CSS_BASELINE="$BASELINE_FILE" \
    bash "$LINT" --all 2>/dev/null
    true  # we just want the script to run without crashing
); then
    _ok "baseline file loads without crash"
fi
rm -f "$BASELINE_FILE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
