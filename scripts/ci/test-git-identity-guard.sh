#!/usr/bin/env bash
# test-git-identity-guard.sh — INFRA-787 fixture tests.
#
# Cases:
#   1. Real identity (jeff@example.com / Jeff) → guard passes
#   2. user.email=t@t.t → guard blocks
#   3. user.name=t → guard blocks
#   4. user.email empty → guard blocks
#   5. CHUMP_GIT_IDENTITY_CHECK=0 → guard skips silently
#
# Each case overrides identity inline via `git -c user.email=... -c user.name=...`
# which is the same mechanism that mutated the real repo's config. We
# invoke the hook directly (not via `git commit`) and the hook reads the
# effective identity via `git var GIT_AUTHOR_IDENT`.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-787 git-identity guard tests ==="
echo

unset GIT_WORK_TREE GIT_DIR GIT_COMMON_DIR

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-git-identity.sh"

if [[ ! -x "$HOOK" ]]; then
    echo "FATAL: hook not executable: $HOOK"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/repo"
mkdir -p "$FAKE"
git -C "$FAKE" init -q -b main

# Use git -c to override the identity per invocation, then run the hook
# in that repo. This simulates what a fixture-mutated config looks like.
# `git var GIT_AUTHOR_IDENT` evaluates the effective identity, which the
# `-c` overrides feed into.
run_hook_with() {
    local email="$1" name="$2"
    cd "$FAKE" || return 2
    GIT_AUTHOR_EMAIL="$email" GIT_AUTHOR_NAME="$name" \
    GIT_COMMITTER_EMAIL="$email" GIT_COMMITTER_NAME="$name" \
        "$HOOK" 2>&1
    RC=$?
    cd - >/dev/null || true
    return "$RC"
}

# ── Test 1: real identity → passes ──────────────────────────────────────────
echo "--- Test 1: real identity → passes ---"
OUT=$(run_hook_with "jeff@example.com" "Jeff Adkins")
RC=$?
if [[ "$RC" -eq 0 ]] && [[ -z "$OUT" ]]; then
    ok "real identity allowed silently"
else
    fail "real identity should pass (rc=$RC, out=$OUT)"
fi

# ── Test 2: t@t.t → blocks ──────────────────────────────────────────────────
echo "--- Test 2: user.email=t@t.t → blocks ---"
OUT=$(run_hook_with "t@t.t" "Real Name")
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q "test-fixture sentinel"; then
    ok "fixture email blocked"
else
    fail "expected block on t@t.t (rc=$RC, out=$OUT)"
fi

# ── Test 3: name=t → blocks ─────────────────────────────────────────────────
echo "--- Test 3: user.name=t → blocks ---"
OUT=$(run_hook_with "real@example.com" "t")
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q "user.name looks like"; then
    ok "fixture name blocked"
else
    fail "expected block on name=t (rc=$RC, out=$OUT)"
fi

# ── Test 4: empty email → blocks ────────────────────────────────────────────
echo "--- Test 4: empty user.email → blocks ---"
OUT=$(run_hook_with "" "Real Name")
RC=$?
if [[ "$RC" -ne 0 ]]; then
    ok "empty email blocked"
else
    fail "expected block on empty email (rc=$RC, out=$OUT)"
fi

# ── Test 5: bypass env → silent skip ────────────────────────────────────────
echo "--- Test 5: CHUMP_GIT_IDENTITY_CHECK=0 → skip ---"
cd "$FAKE" || exit 2
OUT=$(GIT_AUTHOR_EMAIL="t@t.t" GIT_AUTHOR_NAME="t" \
      GIT_COMMITTER_EMAIL="t@t.t" GIT_COMMITTER_NAME="t" \
      CHUMP_GIT_IDENTITY_CHECK=0 \
      "$HOOK" 2>&1)
RC=$?
cd - >/dev/null || true
if [[ "$RC" -eq 0 ]] && [[ -z "$OUT" ]]; then
    ok "bypass env silenced the guard"
else
    fail "bypass should silence (rc=$RC, out=$OUT)"
fi

# ── Test 6: t@t (no .t suffix) also blocked ─────────────────────────────────
echo "--- Test 6: user.email=t@t → blocks ---"
OUT=$(run_hook_with "t@t" "Real Name")
RC=$?
if [[ "$RC" -ne 0 ]]; then
    ok "t@t (no suffix) blocked"
else
    fail "expected block on t@t (rc=$RC, out=$OUT)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
