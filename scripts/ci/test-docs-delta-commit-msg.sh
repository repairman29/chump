#!/usr/bin/env bash
# test-docs-delta-commit-msg.sh — INFRA-1969 regression test.
#
# Verifies that the docs-delta Net-new-docs trailer check works at the
# commit-msg hook stage (where $1 IS the message file path), unlike the
# old pre-commit-stage implementation that always saw empty $MSG_FILE and
# always rejected — forcing CHUMP_DOCS_DELTA_CHECK=0 bypass on every doc PR.
#
# Strategy: stand up a tiny git repo, install the commit-msg hook, then
# attempt commits that add docs/*.md with and without the trailer; assert
# the hook accepts good cases and rejects bad ones with the right exit code.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/commit-msg"

if [[ ! -x "$HOOK" ]]; then
    echo "[FAIL] commit-msg hook not found / not executable at $HOOK"
    exit 1
fi

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q
git config user.email t@t
git config user.name t

# Wire the hook
mkdir -p .git/hooks
ln -sf "$HOOK" .git/hooks/commit-msg

# Helper: commit with a message + assert exit code
# args: <expected_rc> <message>
try_commit() {
    local expected="$1"
    local msg="$2"
    set +e
    git commit -m "$msg" >/dev/null 2>&1
    local rc=$?
    set -e
    if [[ "$rc" -ne "$expected" ]]; then
        echo "[FAIL] expected rc=$expected for msg='$msg' but got rc=$rc"
        return 1
    fi
    return 0
}

# Need an initial commit so git diff --cached works
mkdir -p src
echo "fn main() {}" > src/main.rs
git add src/main.rs
git commit -qm "initial"

# ---- Test 1: adding 1 docs/*.md WITHOUT trailer must be rejected ----
mkdir -p docs
echo "# new doc" > docs/foo.md
git add docs/foo.md
echo "Test 1: docs add without trailer must be rejected"
if try_commit 1 "feat: add foo doc"; then
    echo "[PASS] Test 1: commit-msg rejected missing-trailer commit"
else
    exit 1
fi

# ---- Test 2: adding 1 docs/*.md WITH Net-new-docs: +1 trailer must succeed ----
echo "Test 2: docs add with matching trailer must succeed"
if try_commit 0 "$(printf 'feat: add foo doc\n\nNet-new-docs: +1\n')"; then
    echo "[PASS] Test 2: commit-msg accepted matching trailer"
else
    exit 1
fi

# ---- Test 3: adding 3 docs/*.md with trailer +1 must be rejected (INFRA-124 rule) ----
echo "bar" > docs/bar.md
echo "baz" > docs/baz.md
echo "qux" > docs/qux.md
git add docs/bar.md docs/baz.md docs/qux.md
echo "Test 3: trailer +1 understating actual +3 must be rejected"
if try_commit 1 "$(printf 'feat: add bars\n\nNet-new-docs: +1\n')"; then
    echo "[PASS] Test 3: commit-msg rejected understated trailer (INFRA-124)"
else
    exit 1
fi

# ---- Test 4: trailer +3 matching actual +3 must succeed ----
echo "Test 4: trailer +3 matching actual +3 must succeed"
if try_commit 0 "$(printf 'feat: add bars\n\nNet-new-docs: +3\n')"; then
    echo "[PASS] Test 4: commit-msg accepted matching trailer for 3 docs"
else
    exit 1
fi

# ---- Test 5: CHUMP_DOCS_DELTA_CHECK=0 bypass must allow no-trailer commit ----
echo "more" > docs/more.md
git add docs/more.md
echo "Test 5: CHUMP_DOCS_DELTA_CHECK=0 bypass must allow no-trailer commit"
set +e
CHUMP_DOCS_DELTA_CHECK=0 git commit -m "feat: add more doc" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    echo "[PASS] Test 5: bypass env var works"
else
    echo "[FAIL] Test 5: bypass env var didn't allow commit (rc=$rc)"
    exit 1
fi

# ---- Test 6: zero docs added must pass without trailer ----
echo "fn bar() {}" >> src/main.rs
git add src/main.rs
echo "Test 6: zero docs added must pass without trailer"
if try_commit 0 "fix: tweak main.rs"; then
    echo "[PASS] Test 6: no-docs commit passes silently"
else
    exit 1
fi

echo
echo "[OK] all 6 INFRA-1969 docs-delta commit-msg cases passed"
