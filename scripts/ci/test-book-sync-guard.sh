#!/usr/bin/env bash
# INFRA-170: tests for the book/src ↔ docs/process sync guard in
# scripts/git-hooks/pre-commit. Exercises pass (synced) and fail
# (deliberate drift) cases in a sandbox repo so the guard's logic
# is verifiable without touching the real worktree.
#
# Run from repo root: bash scripts/ci/test-book-sync-guard.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Sandbox setup ────────────────────────────────────────────────────────────
# Build a minimal repo with the exact directory layout the guard expects:
#   docs/process/example.md   ← source-of-truth doc
#   book/src/example.md       ← rendered mirror
#   scripts/dev/sync-book-from-docs.sh  ← canonical sync script
#   scripts/git-hooks/pre-commit ← copied from real repo
git init -q -b main "$SANDBOX"
mkdir -p "$SANDBOX/docs/process" "$SANDBOX/book/src" "$SANDBOX/scripts/dev" "$SANDBOX/scripts/git-hooks"

cat > "$SANDBOX/docs/process/example.md" <<'EOF'
# Example process doc

Original content. Both files start in sync.
EOF
cp "$SANDBOX/docs/process/example.md" "$SANDBOX/book/src/example.md"

# Minimal sync script: just copies docs/process/*.md → book/src/.
cat > "$SANDBOX/scripts/dev/sync-book-from-docs.sh" <<'EOF'
#!/usr/bin/env bash
set -e
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
for src in docs/process/*.md; do
    [ -f "$src" ] || continue
    dst="book/src/$(basename "$src")"
    cp "$src" "$dst"
done
EOF
chmod +x "$SANDBOX/scripts/dev/sync-book-from-docs.sh"

cp "$REPO_ROOT/scripts/git-hooks/pre-commit" "$SANDBOX/scripts/git-hooks/pre-commit"
chmod +x "$SANDBOX/scripts/git-hooks/pre-commit"

git -C "$SANDBOX" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "seed (synced)"
git -C "$SANDBOX" -c core.hooksPath=scripts/git-hooks config core.hooksPath scripts/git-hooks

# Disable other guards that would fire on our minimal sandbox (no .chump-locks,
# no docs/gaps.yaml, no Cargo.toml, etc.). Keep CHUMP_BOOK_SYNC_CHECK at default.
SANDBOX_ENV='CHUMP_LEASE_CHECK=0 CHUMP_STOMP_WARN=0 CHUMP_GAPS_LOCK=0 CHUMP_PREREG_CHECK=0
             CHUMP_CROSS_JUDGE_CHECK=0 CHUMP_SUBMODULE_CHECK=0 CHUMP_CHECK_BUILD=0
             CHUMP_DOCS_DELTA_CHECK=0 CHUMP_CREDENTIAL_CHECK=0 CHUMP_PREREG_CONTENT_CHECK=0
             CHUMP_RAW_YAML_LOCK=0'

# ── case 1: edit docs/process/ AND book/src/ together → guard PASSES ─────────
echo "
Updated content (revision 1)." >> "$SANDBOX/docs/process/example.md"
cp "$SANDBOX/docs/process/example.md" "$SANDBOX/book/src/example.md"
git -C "$SANDBOX" add docs/process/example.md book/src/example.md
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "edit + sync" >/dev/null 2>&1; then
    pass "edit docs/process + matching book/src commits cleanly"
else
    fail "edit + sync was rejected; should pass"
fi

# ── case 2: edit docs/process/ ONLY (no book/src/ stage) → guard FAILS ───────
echo "
Updated content (revision 2 — uncommitted drift)." >> "$SANDBOX/docs/process/example.md"
git -C "$SANDBOX" add docs/process/example.md
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "drift" >/dev/null 2>&1; then
    fail "drifting commit unexpectedly passed; guard should reject"
else
    pass "drifting docs/process edit blocked by guard"
fi

# Recover from case 2's failed commit by syncing manually
bash "$SANDBOX/scripts/dev/sync-book-from-docs.sh" >/dev/null 2>&1 || true
git -C "$SANDBOX" -c user.email=t@t -c user.name=t add book/src/example.md docs/process/example.md
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "rev 2 with sync"

# ── case 3: bypass env CHUMP_BOOK_SYNC_CHECK=0 → guard skips even on drift ───
echo "
Updated content (revision 3 — bypass)." >> "$SANDBOX/docs/process/example.md"
git -C "$SANDBOX" add docs/process/example.md
if env $SANDBOX_ENV CHUMP_BOOK_SYNC_CHECK=0 \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "bypassed drift" >/dev/null 2>&1; then
    pass "CHUMP_BOOK_SYNC_CHECK=0 bypasses the guard"
else
    fail "bypass env didn't allow drifting commit"
fi

# ── case 4: edit something OTHER than docs/process → guard skips ─────────────
echo "non-process file" > "$SANDBOX/scripts/unrelated.sh"
git -C "$SANDBOX" add scripts/unrelated.sh
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "unrelated file" >/dev/null 2>&1; then
    pass "non-docs/process edit skips the guard"
else
    fail "guard incorrectly fired on non-docs/process file"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
