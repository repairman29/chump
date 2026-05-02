#!/usr/bin/env bash
# INFRA-158: regression test for the docs-delta pre-commit guard
# (INFRA-009). Red Letter #3: docs/ grew 66 → 119 → 139 files across
# three review cycles with zero deletions. The guard counter-presses:
# if a commit adds a docs/*.md, require either a deletion of another
# docs/*.md OR a `Net-new-docs:` trailer in the commit message.
# Advisory until 2026-04-28 then blocking. This test exercises the
# behavior that actually works at pre-commit time.
#
# KNOWN LIMITATIONS surfaced while writing this test (filed as
# follow-up notes in CLAUDE.md guards table; not fixed here):
#
#   1. cargo-fmt early-exit at pre-commit:947. If no .rs files are
#      staged, the hook exits 0 before the docs-delta check runs.
#      This means docs-only commits silently bypass docs-delta. The
#      tests below force a .rs file alongside the doc change so
#      docs-delta actually fires.
#
#   2. trailer-blind-spot. The guard checks `$REPO_ROOT/.git/COMMIT_EDITMSG`
#      for a `Net-new-docs:` trailer. But pre-commit hooks run BEFORE
#      git writes the new commit message — so COMMIT_EDITMSG holds
#      the PREVIOUS commit's message at pre-commit time, regardless
#      of `-m`, `-F`, or interactive editor. The trailer escape
#      hatch is therefore unreachable for `git commit`. Fix would
#      require moving the trailer check to a commit-msg hook.
#
# Run from repo root: bash scripts/ci/test-docs-delta-guard.sh

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
git init -q -b main "$SANDBOX"
mkdir -p "$SANDBOX/scripts/git-hooks" "$SANDBOX/src" "$SANDBOX/docs"
cp "$REPO_ROOT/scripts/git-hooks/pre-commit" "$SANDBOX/scripts/git-hooks/pre-commit"
chmod +x "$SANDBOX/scripts/git-hooks/pre-commit"
echo "# existing" > "$SANDBOX/docs/existing.md"
cat > "$SANDBOX/Cargo.toml" <<'EOF'
[package]
name = "sandbox"
version = "0.0.0"
edition = "2021"
EOF
echo "pub fn x() {}" > "$SANDBOX/src/lib.rs"
git -C "$SANDBOX" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$SANDBOX" config core.hooksPath scripts/git-hooks

SANDBOX_ENV='CHUMP_LEASE_CHECK=0 CHUMP_STOMP_WARN=0 CHUMP_GAPS_LOCK=0 CHUMP_PREREG_CHECK=0
             CHUMP_CROSS_JUDGE_CHECK=0 CHUMP_SUBMODULE_CHECK=0 CHUMP_CHECK_BUILD=0
             CHUMP_CREDENTIAL_CHECK=0 CHUMP_PREREG_CONTENT_CHECK=0 CHUMP_RAW_YAML_LOCK=0
             CHUMP_BOOK_SYNC_CHECK=0'

# Helper: clean uncommitted staging from prior case so each case starts fresh.
reset_sandbox() {
    git -C "$SANDBOX" reset --hard HEAD >/dev/null 2>&1 || true
    git -C "$SANDBOX" clean -fd >/dev/null 2>&1 || true
}

# ── case 1: add docs/*.md without delete → guard BLOCKS (post-2026-04-28) ────
reset_sandbox
echo "# new" > "$SANDBOX/docs/new1.md"
echo "// touch" >> "$SANDBOX/src/lib.rs"
git -C "$SANDBOX" add docs/new1.md src/lib.rs
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "add doc no trailer" >/dev/null 2>&1; then
    fail "doc-add without delete unexpectedly committed (post-2026-04-28 blocking date)"
else
    pass "doc-add without delete blocked by guard"
fi

# ── case 2: doc-swap (1 add + 1 delete, net 0) → guard PASSES ────────────────
reset_sandbox
echo "# new2" > "$SANDBOX/docs/new2.md"
git -C "$SANDBOX" rm docs/existing.md >/dev/null
git -C "$SANDBOX" add docs/new2.md
echo "// 2" >> "$SANDBOX/src/lib.rs"
git -C "$SANDBOX" add src/lib.rs
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "swap docs" >/dev/null 2>&1; then
    pass "doc-swap (1 add + 1 delete, net 0) commits cleanly"
else
    fail "doc-swap was rejected; net delta is 0, should pass"
fi

# ── case 3: bypass env CHUMP_DOCS_DELTA_CHECK=0 → guard skips ────────────────
reset_sandbox
echo "# new3" > "$SANDBOX/docs/new3.md"
echo "// 3" >> "$SANDBOX/src/lib.rs"
git -C "$SANDBOX" add docs/new3.md src/lib.rs
if env $SANDBOX_ENV CHUMP_DOCS_DELTA_CHECK=0 \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "bypassed doc-add" >/dev/null 2>&1; then
    pass "CHUMP_DOCS_DELTA_CHECK=0 bypasses the guard"
else
    fail "bypass env didn't allow doc-add"
fi

# ── case 4: docs-only commit (no .rs staged) → cargo-fmt early-exit skips ────
# Documents the limitation: the cargo-fmt early-exit at pre-commit:947
# means docs-only commits never reach the docs-delta check. This case
# verifies that limitation rather than testing the guard itself, so
# future fixes to the early-exit can flip this assertion.
reset_sandbox
echo "# new4" > "$SANDBOX/docs/new4.md"
git -C "$SANDBOX" add docs/new4.md
if env $SANDBOX_ENV \
    git -C "$SANDBOX" -c user.email=t@t -c user.name=t commit -q -m "docs-only add" >/dev/null 2>&1; then
    pass "docs-only commit bypasses guard via cargo-fmt early-exit (limitation acknowledged)"
else
    fail "docs-only commit was unexpectedly blocked — early-exit fixed?"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
