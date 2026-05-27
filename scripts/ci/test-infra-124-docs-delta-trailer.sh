#!/usr/bin/env bash
# test-infra-124-docs-delta-trailer.sh — INFRA-124 regression test.
#
# NOTE (INFRA-1969 / INFRA-2044): The docs-delta Net-new-docs: +N trailer
# check was MOVED from pre-commit to the commit-msg hook by commit 4c769f67a
# (PR #2574). Pre-commit now only emits a non-blocking informational notice;
# enforcement fires at commit-msg stage where $1 is the actual commit message
# file. This test therefore drives fixtures through `git commit` (which fires
# the commit-msg hook) rather than calling pre-commit directly.
#
# Four cases:
#
#   (1) trailer matches actual delta            → accepted (exit 0)
#   (2) trailer understates delta (claim +1, actual +5) → rejected (exit 1)
#   (3) trailer overstates delta  (claim +10, actual +2) → accepted (exit 0)
#   (4) no trailer + adds                       → rejected (exit 1)
#
# Each case spins up a fresh isolated git repo so the diff-filter=A
# (Added-only) query in the hook always sees files as genuinely new.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
COMMIT_MSG_HOOK="$REPO_ROOT/scripts/git-hooks/commit-msg"

if [[ ! -f "$COMMIT_MSG_HOOK" ]]; then
    echo "[FAIL] commit-msg hook not found at $COMMIT_MSG_HOOK"
    exit 1
fi

PARENT_TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$PARENT_TMP"' EXIT

# make_repo — create a fresh isolated git repo under PARENT_TMP/N with the
# commit-msg hook installed and a pre-commit stub (so only the docs-delta
# check runs). Returns the path to the repo via echo.
make_repo() {
    local name="$1"
    local repo="$PARENT_TMP/$name"
    mkdir -p "$repo"
    cd "$repo"
    git init -q -b main
    git config user.email "test@chump.local"
    git config user.name "Chump Test"

    # Install real commit-msg hook (enforcement point post-INFRA-1969).
    mkdir -p .git/hooks
    cp "$COMMIT_MSG_HOOK" .git/hooks/commit-msg
    chmod +x .git/hooks/commit-msg

    # Stub pre-commit: only docs-delta lives in commit-msg; stub removes noise.
    cat > .git/hooks/pre-commit <<'STUB'
#!/usr/bin/env bash
# Stub: pre-commit guards disabled for INFRA-124 docs-delta commit-msg test.
exit 0
STUB
    chmod +x .git/hooks/pre-commit

    mkdir -p docs src
    echo "fn main() {}" > src/main.rs
    echo "init" > README.md
    git add README.md src/main.rs
    git commit -q --no-verify -m "init"
    echo "$repo"
}

# run_check REPO N_ADDED COMMIT_MSG
# Stages N_ADDED new docs/*.md files in REPO, then attempts git commit with
# COMMIT_MSG (which fires the commit-msg hook). Returns the exit code of
# `git commit`. Each file is freshly added (never committed before) so
# diff-filter=A correctly counts them.
run_check() {
    local repo="$1"
    local n_added="$2"
    local commit_msg="$3"

    cd "$repo"
    for i in $(seq 1 "$n_added"); do
        echo "doc $i" > "docs/test-${i}.md"
        git add "docs/test-${i}.md"
    done
    # Stage a src change so there's always something to commit beyond docs.
    echo "fn main() { /* run $RANDOM */ }" > src/main.rs
    git add src/main.rs

    set +e
    git commit -q -m "$commit_msg" >/tmp/infra-124-test-out 2>&1
    local rc=$?
    set -e
    return $rc
}

PASS=0
FAIL=0

# ── Test 1: trailer matches → accepted ───────────────────────────────────────
echo "Test 1: trailer +5 matches actual +5 → expect accept"
REPO1="$(make_repo repo1)"
if run_check "$REPO1" 5 "$(printf 'test commit\n\nNet-new-docs: +5')"; then
    echo "[PASS] trailer matching delta accepted"
    PASS=$((PASS + 1))
else
    echo "[FAIL] trailer matching delta should accept"
    cat /tmp/infra-124-test-out >&2 || true
    FAIL=$((FAIL + 1))
fi

# ── Test 2: trailer understates → rejected (INFRA-124 fix) ───────────────────
echo ""
echo "Test 2: trailer +1 understates actual +5 → expect reject"
REPO2="$(make_repo repo2)"
if run_check "$REPO2" 5 "$(printf 'test commit\n\nNet-new-docs: +1')"; then
    echo "[FAIL] INFRA-124 regression: trailer +1 should be rejected when actual is +5"
    cat /tmp/infra-124-test-out >&2 || true
    FAIL=$((FAIL + 1))
else
    echo "[PASS] understated trailer rejected (INFRA-124 rule enforced by commit-msg hook)"
    PASS=$((PASS + 1))
fi

# ── Test 3: trailer overstates → accepted ────────────────────────────────────
echo ""
echo "Test 3: trailer +10 overstates actual +2 → expect accept"
REPO3="$(make_repo repo3)"
if run_check "$REPO3" 2 "$(printf 'test commit\n\nNet-new-docs: +10')"; then
    echo "[PASS] over-declared trailer accepted (intentional batch declaration)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] over-declared trailer should be accepted"
    cat /tmp/infra-124-test-out >&2 || true
    FAIL=$((FAIL + 1))
fi

# ── Test 4: no trailer + adds → blocked ──────────────────────────────────────
echo ""
echo "Test 4: no trailer with +3 docs added → expect block"
REPO4="$(make_repo repo4)"
if run_check "$REPO4" 3 "test commit no trailer"; then
    echo "[FAIL] missing trailer should block when adding docs"
    cat /tmp/infra-124-test-out >&2 || true
    FAIL=$((FAIL + 1))
else
    echo "[PASS] missing trailer blocks as expected"
    PASS=$((PASS + 1))
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "[FAIL] $FAIL/$((PASS + FAIL)) INFRA-124 trailer-validation cases failed"
    exit 1
fi
echo "[OK] all $PASS INFRA-124 trailer-validation cases passed"
