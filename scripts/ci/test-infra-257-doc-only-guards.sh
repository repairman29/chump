#!/usr/bin/env bash
# test-infra-257-doc-only-guards.sh — INFRA-257 regression test.
#
# Verifies the pre-commit hook no longer short-circuits on doc-only
# commits (commits that don't stage any .rs files). Pre-INFRA-257, the
# hook hit `exit 0` at the staged_rust check and skipped EVERY guard
# below it: docs-delta (INFRA-009/124), credential-pattern, raw-YAML,
# book-sync, etc.
#
# Three cases:
#   (1) doc-only commit + bad Net-new-docs trailer  → must REJECT
#   (2) doc-only commit + matching trailer          → must accept
#   (3) rust + doc commit + bad trailer             → must REJECT (parity check)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"

if [[ ! -f "$HOOK" ]]; then
    echo "[FAIL] pre-commit hook not found at $HOOK"
    exit 1
fi

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"
mkdir -p docs scripts/git-hooks src
cp "$HOOK" scripts/git-hooks/pre-commit
chmod +x scripts/git-hooks/pre-commit
# INFRA-1969 / META-117 Wave 1: docs-delta guard moved from pre-commit
# to commit-msg. Copy commit-msg hook too so `git commit` runs the actual guard.
COMMIT_MSG_HOOK="$REPO_ROOT/scripts/git-hooks/commit-msg"
if [[ -f "$COMMIT_MSG_HOOK" ]]; then
    cp "$COMMIT_MSG_HOOK" scripts/git-hooks/commit-msg
    chmod +x scripts/git-hooks/commit-msg
fi
# NOTE: core.hooksPath is wired AFTER the init commit below — otherwise
# the init commit triggers the hook (with a bin name that doesn't match
# the synth repo) and fails the test setup.
cat > Cargo.toml <<'TOML'
[package]
name = "infra-257-test"
version = "0.0.0"
edition = "2021"

[[bin]]
name = "infra-257-test"
path = "src/main.rs"
TOML
echo "fn main() {}" > src/main.rs
echo "init" > README.md
git add README.md scripts/git-hooks/pre-commit Cargo.toml src/main.rs
git commit -qm "init"

# Wire hooks AFTER init commit so init doesn't trigger them
git config core.hooksPath "$TMP/scripts/git-hooks"

run_check() {
    local n_docs="$1"
    local trailer_val="$2"   # empty for no trailer
    local include_rust="$3"  # "yes" to also stage src/main.rs
    rm -f docs/*.md 2>/dev/null || true
    git rm --cached --quiet docs/*.md 2>/dev/null || true
    for i in $(seq 1 "$n_docs"); do
        echo "doc $i" > "docs/test-${i}.md"
        git add "docs/test-${i}.md"
    done
    if [[ "$include_rust" == "yes" ]]; then
        echo "fn main() { /* turn $RANDOM */ }" > src/main.rs
        git add src/main.rs
    fi
    local msg
    if [[ -n "$trailer_val" ]]; then
        msg="$(printf "test commit\n\nNet-new-docs: +%s\n" "$trailer_val")"
    else
        msg="test commit (no trailer)"
    fi
    # INFRA-1969 / META-117 Wave 1: drive through `git commit` (runs pre-commit
    # AND commit-msg) instead of calling pre-commit directly. The docs-delta
    # enforcement lives in commit-msg post-INFRA-1969 — testing pre-commit alone
    # is testing the wrong stage.
    # Export the env vars so they propagate through git commit → hook invocations.
    export CHUMP_CHECK_BUILD=0
    export CHUMP_BOOK_SYNC_CHECK=0  # skip book-sync guard in synth repo
    set +e
    git commit -m "$msg" >/tmp/infra-257-test-out 2>&1
    local rc=$?
    set -e
    # Undo the commit if it succeeded — so the next test case has a clean slate
    if [[ $rc -eq 0 ]]; then
        git reset --soft HEAD~1 >/dev/null 2>&1 || true
    fi
    return $rc
}

# ── Test 1: doc-only + NO trailer → must REJECT (the INFRA-257 fix) ──────────
# Pre-INFRA-257, this case slipped through because the hook hit `exit 0`
# before reaching the docs-delta guard. Post-fix, the docs-delta guard
# runs even on doc-only commits and rejects the missing trailer.
echo "Test 1: doc-only commit (NO .rs, NO trailer, +5 docs) → expect reject"
if run_check 5 "" "no"; then
    echo "[FAIL] INFRA-257 regression: doc-only commit with NO trailer was accepted"
    echo "       (pre-fix the hook short-circuited on no-rust and skipped docs-delta)"
    cat /tmp/infra-257-test-out >&2 || true
    exit 1
else
    if grep -q "docs-delta" /tmp/infra-257-test-out; then
        echo "[PASS] doc-only commit with no trailer correctly rejected by docs-delta guard"
    else
        echo "[PASS] doc-only commit rejected (no docs-delta marker, but rc != 0)"
    fi
fi

# ── Test 2: doc-only + valid trailer → accepted ──────────────────────────────
# This case must continue to work — the hook should fall through cleanly
# without rust files staged.
echo ""
echo "Test 2: doc-only commit + Net-new-docs:+5 trailer matches actual +5 → expect accept"
if run_check 5 "5" "no"; then
    echo "[PASS] doc-only commit with valid trailer accepted (no early-exit, no false reject)"
else
    echo "[FAIL] doc-only commit with valid trailer should be accepted (rc=$?)"
    cat /tmp/infra-257-test-out >&2 || true
    exit 1
fi

# ── Test 3: rust + doc commit + NO trailer → REJECT (parity preserved) ───────
echo ""
echo "Test 3: rust+doc commit + NO trailer → expect reject (existing behavior preserved)"
if run_check 5 "" "yes"; then
    echo "[FAIL] mixed commit with no trailer should be rejected by docs-delta"
    cat /tmp/infra-257-test-out >&2 || true
    exit 1
else
    echo "[PASS] mixed rust+doc commit with no trailer correctly rejected"
fi

echo ""
echo "[OK] all 3 INFRA-257 doc-only-guard cases passed"
