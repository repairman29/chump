#!/usr/bin/env bash
# INFRA-158: regression test for the submodule-sanity pre-commit guard
# (INFRA-018). Original incident: commit 08da134 added a sql-migrate
# gitlink (mode 160000) without an entry in .gitmodules, breaking
# actions/checkout submodule init on every PR for ~20 stalled CI runs
# until PR #103 removed it. The guard rejects new gitlinks that lack a
# matching .gitmodules entry. This test exercises pass/fail/bypass.
#
# Run from repo root: bash scripts/ci/test-submodule-guard.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Sandbox: minimal repo with the real pre-commit hook installed ────────────
git init -q -b main "$SANDBOX"
mkdir -p "$SANDBOX/scripts/git-hooks"
cp "$REPO_ROOT/scripts/git-hooks/pre-commit" "$SANDBOX/scripts/git-hooks/pre-commit"
chmod +x "$SANDBOX/scripts/git-hooks/pre-commit"
echo "init" > "$SANDBOX/README.md"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$SANDBOX" config core.hooksPath scripts/git-hooks

# Disable other guards that would interfere on this minimal sandbox.
SANDBOX_ENV='CHUMP_LEASE_CHECK=0 CHUMP_STOMP_WARN=0 CHUMP_GAPS_LOCK=0 CHUMP_PREREG_CHECK=0
             CHUMP_CROSS_JUDGE_CHECK=0 CHUMP_CHECK_BUILD=0 CHUMP_DOCS_DELTA_CHECK=0
             CHUMP_CREDENTIAL_CHECK=0 CHUMP_PREREG_CONTENT_CHECK=0 CHUMP_RAW_YAML_LOCK=0
             CHUMP_BOOK_SYNC_CHECK=0'

# ── case 1: add a gitlink WITHOUT .gitmodules → guard FAILS ──────────────────
# Use git update-index to fabricate a gitlink (mode 160000) without
# actually cloning a sub-repo.
git -C "$SANDBOX" update-index --add --cacheinfo 160000,$(git -C "$SANDBOX" rev-parse HEAD),vendored-thing
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "dangling gitlink" >/dev/null 2>&1; then
    fail "dangling gitlink unexpectedly committed"
else
    pass "dangling gitlink (no .gitmodules entry) blocked by guard"
fi
git -C "$SANDBOX" reset HEAD vendored-thing >/dev/null 2>&1 || true
git -C "$SANDBOX" rm --cached vendored-thing >/dev/null 2>&1 || true

# ── case 2: add gitlink WITH matching .gitmodules entry → guard PASSES ───────
cat > "$SANDBOX/.gitmodules" <<'EOF'
[submodule "vendored-thing"]
	path = vendored-thing
	url = https://example.invalid/repo.git
EOF
git -C "$SANDBOX" update-index --add --cacheinfo 160000,$(git -C "$SANDBOX" rev-parse HEAD),vendored-thing
git -C "$SANDBOX" add .gitmodules
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "with .gitmodules" >/dev/null 2>&1; then
    pass "gitlink + matching .gitmodules entry commits cleanly"
else
    fail "gitlink with .gitmodules was rejected; should pass"
fi

# ── case 3: bypass env CHUMP_SUBMODULE_CHECK=0 → guard skips ─────────────────
git -C "$SANDBOX" rm -rf .gitmodules vendored-thing >/dev/null 2>&1 || true
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "remove" >/dev/null 2>&1 || true
git -C "$SANDBOX" update-index --add --cacheinfo 160000,$(git -C "$SANDBOX" rev-parse HEAD),vendored-thing
if env $SANDBOX_ENV CHUMP_SUBMODULE_CHECK=0 \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "bypassed" >/dev/null 2>&1; then
    pass "CHUMP_SUBMODULE_CHECK=0 bypasses the guard"
else
    fail "bypass env didn't allow dangling gitlink"
fi

# ── case 4: regular file commit (no gitlinks) → guard skips silently ─────────
git -C "$SANDBOX" reset --hard HEAD >/dev/null 2>&1 || true
echo "more" >> "$SANDBOX/README.md"
git -C "$SANDBOX" add README.md
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "regular file" >/dev/null 2>&1; then
    pass "regular file commit skips the guard"
else
    fail "guard incorrectly fired on regular file"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
