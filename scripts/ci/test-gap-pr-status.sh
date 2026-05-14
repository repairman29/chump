#!/usr/bin/env bash
# scripts/ci/test-gap-pr-status.sh — INFRA-1221

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/coord/lib/gap-pr-status.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -f "$LIB" ] || fail "library missing"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view") echo "fake-owner/fake-repo"; exit 0 ;;
    "api repos"*)
        [[ -f "${FAKE_PRS_FILE:-}" ]] && cat "$FAKE_PRS_FILE" || echo ""
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
# shellcheck disable=SC1090
source "$LIB"

# Test 1: empty list → no PR
: > "$TMP/empty"
if FAKE_PRS_FILE="$TMP/empty" gap_has_open_pr "INFRA-100"; then fail "empty list → no PR expected"; fi
ok "empty list → gap_has_open_pr returns 1"

# Test 2: matching open PR → has PR
cat > "$TMP/match" <<'EOF'
1234 feat(INFRA-100): something
EOF
FAKE_PRS_FILE="$TMP/match" gap_has_open_pr "INFRA-100" || fail "open PR should match"
got=$(FAKE_PRS_FILE="$TMP/match" gap_open_pr_number "INFRA-100")
[ "$got" = "1234" ] || fail "expected PR number 1234, got '$got'"
ok "matching open PR → gap_has_open_pr=0 + number 1234"

# Test 3: word boundary — INFRA-12 ≠ INFRA-123
cat > "$TMP/boundary" <<'EOF'
9999 feat(INFRA-123): not the same gap
EOF
if FAKE_PRS_FILE="$TMP/boundary" gap_has_open_pr "INFRA-12"; then
    fail "INFRA-12 should NOT match INFRA-123"
fi
ok "word boundary respected (INFRA-12 vs INFRA-123)"

# Test 4: multiple PRs same gap
cat > "$TMP/multi" <<'EOF'
1234 feat(INFRA-200): try 1
5678 feat(INFRA-200): try 2
EOF
got=$(FAKE_PRS_FILE="$TMP/multi" gap_open_pr_number "INFRA-200" | sort | tr '\n' ' ')
[ "$got" = "1234 5678 " ] || fail "expected '1234 5678', got '$got'"
ok "multiple PRs for same gap → all numbers returned"

echo
echo "All INFRA-1221 gap-pr-status tests passed."
