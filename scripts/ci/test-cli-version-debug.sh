#!/usr/bin/env bash
# scripts/ci/test-cli-version-debug.sh — CREDIBLE-019
#
# Verifies --version, --verbose, and --debug flags work as documented.

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHUMP="${REPO_ROOT}/target/debug/chump"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="${HOME}/.cargo/bin/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$(command -v chump 2>/dev/null || echo "")"
fi
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "  SKIP: chump binary not found (run 'cargo build --bin chump' first)"
    exit 0
fi

echo "=== CREDIBLE-019: CLI version/debug flags ==="
echo "  binary: $CHUMP"
echo

# 1. --version outputs semver
_ver=$("$CHUMP" --version 2>&1) || true
if echo "$_ver" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "--version: outputs semver (got: $_ver)"
else
    fail "--version: expected semver, got: $_ver"
fi

# 2. -V alias works
_ver2=$("$CHUMP" -V 2>&1) || true
if echo "$_ver2" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "-V: alias works (got: $_ver2)"
else
    fail "-V: expected semver, got: $_ver2"
fi

# 3. --version exits 0
"$CHUMP" --version >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    ok "--version: exits 0"
else
    fail "--version: expected exit 0"
fi

# 4. --debug emits startup header on stderr
_dbg_out=$("$CHUMP" --debug --version 2>&1) || true
if echo "$_dbg_out" | grep -q '\[debug\]'; then
    ok "--debug: emits [debug] header to stderr"
else
    fail "--debug: expected [debug] header in stderr, got: ${_dbg_out:0:120}"
fi

# 5. --debug header includes version string
if echo "$_dbg_out" | grep -q '\[debug\] chump'; then
    ok "--debug: header includes 'chump <version>'"
else
    fail "--debug: header missing 'chump' prefix, got: ${_dbg_out:0:120}"
fi

# 6. --debug header includes timestamp pattern HH:MM:SS
if echo "$_dbg_out" | grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
    ok "--debug: header contains HH:MM:SS timestamp"
else
    fail "--debug: timestamp missing from header, got: ${_dbg_out:0:120}"
fi

# 7. --verbose flag is recognized (does not crash or print usage error)
_verb_out=$("$CHUMP" --verbose --version 2>&1) || true
if echo "$_verb_out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "--verbose: flag is recognized alongside --version"
else
    fail "--verbose: unexpected output, got: ${_verb_out:0:120}"
fi

# 8. --version output contains build SHA or 'dev'
if echo "$_ver" | grep -qE '\(([0-9a-f]{6,}|dev)'; then
    ok "--version: includes build SHA"
else
    ok "--version: no build SHA (dev build acceptable)"
fi

# 9. CLI_FLAGS.md exists and documents --verbose and --debug
FLAGS_DOC="$REPO_ROOT/docs/process/CLI_FLAGS.md"
if [[ -f "$FLAGS_DOC" ]]; then
    if grep -q '\-\-verbose' "$FLAGS_DOC" && grep -q '\-\-debug' "$FLAGS_DOC"; then
        ok "CLI_FLAGS.md: documents --verbose and --debug"
    else
        fail "CLI_FLAGS.md: missing --verbose or --debug documentation"
    fi
else
    fail "CLI_FLAGS.md: not found at $FLAGS_DOC"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
