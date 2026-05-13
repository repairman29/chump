#!/usr/bin/env bash
# test-github-api-telemetry-shim.sh — INFRA-999 PATH shim coverage test.
#
# Verifies that sourcing scripts/coord/lib/github.sh activates the gh
# PATH shim so every raw `gh ...` call gets recorded — not just calls
# that explicitly use chump_gh / chump_gh_record.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github.sh"
SHIM_DIR="$REPO_ROOT/scripts/coord/lib/gh-shim"

[[ -f "$LIB" ]] || { echo "FAIL: $LIB missing"; exit 1; }
[[ -x "$SHIM_DIR/gh" ]] || { echo "FAIL: shim not executable"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AMBIENT="$TMP/ambient.jsonl"

# Mock gh that writes to a sentinel + returns 0. Place in TMP so the shim
# walks past TMP (its dir, after prepending) and finds the mock.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "mock-gh-was-called args=$*" >> "${MOCK_GH_LOG:?}"
case "${1:-}" in
    api)
        if [[ "${2:-}" == "rate_limit" ]]; then
            echo "1000 999"  # core graphql
            exit 0
        fi
        ;;
esac
echo "mock-gh-default-stdout"
exit 0
EOF
chmod +x "$TMP/bin/gh"

# ── Scenario 1: sourcing the lib activates the shim on PATH ──────────────────
out="$(
    PATH="$TMP/bin:$PATH" \
    CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
    MOCK_GH_LOG="$TMP/mock-calls.log" \
    bash -c "
        source '$LIB'
        # Shim dir should now be FIRST in PATH
        first=\"\${PATH%%:*}\"
        echo \"first=\$first\"
        which gh
        gh --version >/dev/null
        gh api rate_limit --jq '.foo' >/dev/null 2>&1 || true
    "
)"
echo "$out" | grep -q "first=$SHIM_DIR" \
    && ok "shim dir is prepended to PATH on source" \
    || fail "shim dir not first in PATH. out: $out"
echo "$out" | grep -q "$SHIM_DIR/gh" \
    && ok "which gh resolves to shim" \
    || fail "which gh did not resolve to shim. out: $out"

# Verify ambient got both calls
ambient_count=$(grep -c 'github_api_call' "$AMBIENT" 2>/dev/null || echo 0)
[[ "$ambient_count" -ge 2 ]] \
    && ok "$ambient_count github_api_call events in ambient" \
    || fail "expected ≥2 ambient events, got $ambient_count"

# Verify mock-gh was called (not infinite-loop)
mock_count=$(wc -l < "$TMP/mock-calls.log" 2>/dev/null | tr -d ' ' || echo 0)
[[ "$mock_count" -ge 2 ]] \
    && ok "mock real-gh called $mock_count times (no infinite-recursion)" \
    || fail "expected mock gh called ≥2 times, got $mock_count"

# Verify api_tag parsing
grep -q '"api":"--version"' "$AMBIENT" \
    && ok "--version tagged correctly" \
    || fail "--version tag missing. ambient: $(cat $AMBIENT)"
grep -q '"api":"api rate_limit"' "$AMBIENT" \
    && ok "'api rate_limit' tagged correctly" \
    || fail "'api rate_limit' tag missing"

# ── Scenario 2: CHUMP_GH_NO_PATH_INJECT=1 opts out ───────────────────────────
rm -f "$AMBIENT" "$TMP/mock-calls.log"
out2="$(
    PATH="$TMP/bin:$PATH" \
    CHUMP_GH_NO_PATH_INJECT=1 \
    CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
    MOCK_GH_LOG="$TMP/mock-calls.log" \
    bash -c "
        source '$LIB'
        echo \"first=\${PATH%%:*}\"
    "
)"
echo "$out2" | grep -q "first=$TMP/bin" \
    && ok "CHUMP_GH_NO_PATH_INJECT=1 prevents shim activation" \
    || fail "opt-out failed. out: $out2"

# ── Scenario 3: CHUMP_GH_NO_SHIM=1 bypasses the shim per-call ────────────────
rm -f "$AMBIENT" "$TMP/mock-calls.log"
PATH="$TMP/bin:$PATH" \
CHUMP_AMBIENT_OVERRIDE="$AMBIENT" \
MOCK_GH_LOG="$TMP/mock-calls.log" \
bash -c "
    source '$LIB'
    CHUMP_GH_NO_SHIM=1 gh --version >/dev/null
" 2>&1 >/dev/null
ambient_after=$(grep -c 'github_api_call' "$AMBIENT" 2>/dev/null || echo 0)
[[ "$ambient_after" -eq 0 ]] \
    && ok "CHUMP_GH_NO_SHIM=1 per-call bypass: no ambient event recorded" \
    || fail "per-call bypass failed: $ambient_after events recorded"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
