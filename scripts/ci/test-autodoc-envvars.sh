#!/usr/bin/env bash
# test-autodoc-envvars.sh — RESILIENT-207
#
# Validates the pre-commit env-var auto-documenter:
#   1. A staged code change introducing a NEW CHUMP_* var → the var is appended to
#      env-vars-internal.txt AND the file is re-staged (so the commit carries the doc).
#   2. An already-documented var → NOT re-appended (idempotent).
#   3. A docs-only staged change → no-op (doesn't touch the env file).
#   4. CHUMP_AUTO_ENVVAR=0 → disabled.
#   5. It never fails: the hook always exits 0 (non-blocking).
#
# NOTE: fixture var names are built at runtime from $PFX so this test FILE contains no
# literal CHUMP_<NAME> token — otherwise committing the test would itself trip the real
# env-var-coverage + no-new-bypass-env-vars gates on its own fixture strings (self-pollution).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-autodoc-envvars.sh"
PFX="CHUMP" # concatenated below so no literal CHUMP_<NAME> appears in this file
SEEDED="${PFX}_EXISTING_FIXVAR"
NEWV="${PFX}_BRAND_NEW_FIXVAR"
NEWV2="${PFX}_SECOND_FIXVAR"
PASS=0; FAIL=0
ok(){ printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail(){ printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== RESILIENT-207 env-var auto-doc test ==="
[ -x "$HOOK" ] || { echo "FAIL: $HOOK missing/not executable"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q; git config user.email t@t; git config user.name t
mkdir -p scripts/ci
printf '%s\n' "$SEEDED" > scripts/ci/env-vars-internal.txt
git add -A; git commit -qm seed

# 1. new var in a staged .rs → appended + re-staged
printf 'fn f() { let _ = std::env::var("%s"); }\n' "$NEWV" > src.rs
git add src.rs
"$HOOK" >/dev/null 2>&1 || true
if grep -qE "^${NEWV}\b" scripts/ci/env-vars-internal.txt; then
    ok "new CHUMP_* var appended to env-vars-internal.txt"
else
    fail "new var NOT appended (the CI failure would persist)"
fi
if git diff --cached --name-only | grep -q 'scripts/ci/env-vars-internal.txt'; then
    ok "env-vars-internal.txt re-staged (commit will carry the doc)"
else
    fail "env file not staged — the commit would still fail CI"
fi

# 2. idempotent: running again doesn't duplicate
before="$(grep -c "$NEWV" scripts/ci/env-vars-internal.txt)"
"$HOOK" >/dev/null 2>&1 || true
after="$(grep -c "$NEWV" scripts/ci/env-vars-internal.txt)"
[ "$before" = "$after" ] && ok "idempotent — documented var not re-appended" || fail "re-appended (before=$before after=$after)"

# 3. docs-only change → no-op
git commit -qm "wip" 2>/dev/null || true
echo "hi" > README.md; git add README.md
sum_before="$(cksum scripts/ci/env-vars-internal.txt)"
"$HOOK" >/dev/null 2>&1 || true
sum_after="$(cksum scripts/ci/env-vars-internal.txt)"
[ "$sum_before" = "$sum_after" ] && ok "docs-only change → env file untouched" || fail "env file changed on a docs-only commit"

# 4. bypass
printf 'fn g() { let _ = std::env::var("%s"); }\n' "$NEWV2" > src2.rs
git add src2.rs
CHUMP_AUTO_ENVVAR=0 "$HOOK" >/dev/null 2>&1 || true
grep -qE "^${NEWV2}\b" scripts/ci/env-vars-internal.txt \
    && fail "bypass ignored (var appended despite CHUMP_AUTO_ENVVAR=0)" \
    || ok "CHUMP_AUTO_ENVVAR=0 → disabled"

# 5. never fails
"$HOOK" >/dev/null 2>&1 && ok "hook exits 0 (non-blocking, never fails a commit)" || fail "hook exited non-zero (would block commits)"

echo "=== env-var auto-doc: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
