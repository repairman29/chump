#!/usr/bin/env bash
# test-get-active-claim-file.sh — CREDIBLE-294
#
# Regression test for scripts/coord/lib/lease.sh get_active_claim_file().
# Prior behavior did a blind `head -1` over .chump-locks/claim-*.json, so a
# STALE claim left by a prior ship (e.g. claim-resilient-355-*.json) could be
# matched against a commit for a totally different gap (e.g. RESILIENT-361),
# tripping the RESILIENT-025 pre-commit gate ("must mention claimed gap
# RESILIENT-355") on an unrelated commit. The fix derives the gap id from the
# current branch (chump/<domain>-<num>-...) and matches only that gap's
# claim file, so a leftover claim for a different gap is never enforced.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/lease.sh"

echo "=== CREDIBLE-294 get_active_claim_file branch-matching tests ==="
[[ -f "$LIB" ]] || { fail "lib missing: $LIB"; echo "FAIL"; exit 1; }
ok "lib present at $LIB"

# shellcheck disable=SC1090
source "$LIB"

TMP="$(mktemp -d -t claim-file-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Set up a throwaway git repo so `git rev-parse --abbrev-ref HEAD` inside
# get_active_claim_file resolves to a branch we control.
git -C "$TMP" init -q
git -C "$TMP" config user.email "test@example.com"
git -C "$TMP" config user.name "test"
git -C "$TMP" commit --allow-empty -q -m "init"

mkdir -p "$TMP/.chump-locks"

# Fixture: a STALE claim left by a prior ship for a DIFFERENT gap, plus the
# claim for the gap this branch is actually shipping.
cat > "$TMP/.chump-locks/claim-resilient-355-pid-epoch.json" <<'EOF'
{"session_id": "claim-resilient-355-pid-epoch", "gap_id": "RESILIENT-355"}
EOF
cat > "$TMP/.chump-locks/claim-resilient-361-pid-epoch.json" <<'EOF'
{"session_id": "claim-resilient-361-pid-epoch", "gap_id": "RESILIENT-361"}
EOF

# ── Branch matches RESILIENT-361 → must pick that claim, not the stale one ──
git -C "$TMP" checkout -q -b chump/resilient-361-fix-something
got="$(cd "$TMP" && get_active_claim_file "$TMP")"
if [[ "$got" == *claim-resilient-361-pid-epoch.json ]]; then
    ok "branch chump/resilient-361-* matches its own claim, ignores stale sibling"
else
    fail "branch-matched claim got='$got' want=*claim-resilient-361-pid-epoch.json"
fi

# ── Branch has no matching claim at all → must NOT fall back to the stale one ──
git -C "$TMP" checkout -q -b chump/infra-999-unrelated
got="$(cd "$TMP" && get_active_claim_file "$TMP")"
if [[ -z "$got" ]]; then
    ok "branch with no matching claim returns empty (stale sibling not enforced)"
else
    fail "expected empty for unmatched branch, got='$got'"
fi

# ── Branch carries no gap id (e.g. main) → legacy head-1 behaviour ──
git -C "$TMP" checkout -q main 2>/dev/null || git -C "$TMP" checkout -q master 2>/dev/null || true
got="$(cd "$TMP" && get_active_claim_file "$TMP")"
if [[ -n "$got" && ( "$got" == *claim-resilient-355-pid-epoch.json || "$got" == *claim-resilient-361-pid-epoch.json ) ]]; then
    ok "gap-less branch (main) falls back to legacy head-1 over claim-*.json"
else
    fail "gap-less branch fallback got='$got'"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
