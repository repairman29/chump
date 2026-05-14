#!/usr/bin/env bash
# scripts/ci/test-pr-dedup.sh — INFRA-1219
#
# Verifies the pre-pr-create dedup gate:
#   1. No open PRs → check_pr_dedup returns 0 (no-op)
#   2. Open PR exists for same gap ID on different branch → returns 1
#   3. Open PR exists but it's on the current branch → returns 0 (re-push)
#   4. CHUMP_PR_DEDUP_BYPASS=1 → bypass even when dup exists
#   5. Empty gap-id list → returns 0
#   6. Word-boundary: INFRA-12 does NOT match INFRA-123

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/coord/lib/pr-dedup.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$LIB" ] || fail "library missing: $LIB"

# Stub `gh` so the tests don't hit GitHub. Returns whatever's in FAKE_PRS_FILE.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view")
        echo "fake-owner/fake-repo"; exit 0 ;;
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

# ── Test 1: empty fake list → no violation ─────────────────────────────────
: > "$TMP/empty.txt"
FAKE_PRS_FILE="$TMP/empty.txt" check_pr_dedup "chump/foo" "INFRA-100" \
    || fail "empty PR list should allow"
ok "empty PR list → allow"

# ── Test 2: open PR on different branch for same gap → block ───────────────
cat > "$TMP/dup.txt" <<'EOF'
1234 chump/infra-100-claim-old fix(INFRA-100): older attempt
EOF
err=$(FAKE_PRS_FILE="$TMP/dup.txt" check_pr_dedup "chump/infra-100-claim-new" "INFRA-100" 2>&1)
rc=$?
[ "$rc" -eq 1 ] || fail "expected refusal (rc=1), got rc=$rc"
echo "$err" | grep -q '1234' || fail "violation msg must cite the conflicting PR number"
ok "same gap-id, different branch → refuse with citation"

# ── Test 3: open PR on current branch → allow (re-push case) ───────────────
cat > "$TMP/self.txt" <<'EOF'
1234 chump/infra-100-claim fix(INFRA-100): in-progress
EOF
FAKE_PRS_FILE="$TMP/self.txt" check_pr_dedup "chump/infra-100-claim" "INFRA-100" \
    || fail "self-branch should allow (re-push)"
ok "open PR on current branch → allow (re-push)"

# ── Test 4: CHUMP_PR_DEDUP_BYPASS=1 → allow even with dup ──────────────────
CHUMP_PR_DEDUP_BYPASS=1 FAKE_PRS_FILE="$TMP/dup.txt" \
    check_pr_dedup "chump/infra-100-claim-new" "INFRA-100" \
    || fail "BYPASS=1 should allow"
ok "CHUMP_PR_DEDUP_BYPASS=1 → bypass"

# ── Test 5: no gap IDs supplied → allow ────────────────────────────────────
FAKE_PRS_FILE="$TMP/dup.txt" check_pr_dedup "chump/anything" \
    || fail "empty gap-id list should allow"
ok "no gap IDs supplied → allow"

# ── Test 6: word-boundary — INFRA-12 vs INFRA-123 ──────────────────────────
cat > "$TMP/boundary.txt" <<'EOF'
9999 chump/infra-123-claim feat(INFRA-123): unrelated work
EOF
FAKE_PRS_FILE="$TMP/boundary.txt" check_pr_dedup "chump/whatever" "INFRA-12" \
    || fail "INFRA-12 must NOT match INFRA-123 (word boundary)"
ok "word-boundary: INFRA-12 does not match INFRA-123"

# ── Test 7: multiple gap IDs — one matches → block ─────────────────────────
err=$(FAKE_PRS_FILE="$TMP/dup.txt" check_pr_dedup "chump/x" "INFRA-200" "INFRA-100" "INFRA-300" 2>&1)
rc=$?
[ "$rc" -eq 1 ] || fail "expected refusal when one of N gaps duplicates"
echo "$err" | grep -q '100' || fail "must call out INFRA-100"
ok "multi-gap: one duplicate is enough to refuse"

echo
echo "All INFRA-1219 pr-dedup tests passed."
