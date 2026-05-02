#!/usr/bin/env bash
# test-infra-124-docs-delta-trailer.sh — INFRA-124 regression test.
#
# Verifies that the docs-delta pre-commit guard validates the
# Net-new-docs: +N trailer against the actual computed delta. Three cases:
#
#   (1) trailer matches actual delta            → accepted (exit 0)
#   (2) trailer understates delta (claim +1, actual +5) → rejected (exit 1)
#   (3) trailer overstates delta  (claim +10, actual +2) → accepted (exit 0)
#
# The test isolates the delta-checking block by extracting it into a
# tiny standalone script and feeding it staged-file fixtures.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"

if [[ ! -f "$HOOK" ]]; then
    echo "[FAIL] pre-commit hook not found at $HOOK"
    exit 1
fi

# ── Setup: temp git repo to stage real files + invoke the hook ────────────────
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"
mkdir -p docs scripts/git-hooks src
cp "$HOOK" scripts/git-hooks/pre-commit
chmod +x scripts/git-hooks/pre-commit
# Minimal Cargo.toml so the hook's cargo-fmt step doesn't bail.
cat > Cargo.toml <<'TOML'
[package]
name = "infra-124-test"
version = "0.0.0"
edition = "2021"

[[bin]]
name = "infra-124-test"
path = "src/main.rs"
TOML
echo "fn main() {}" > src/main.rs
echo "init" > README.md
git add README.md scripts/git-hooks/pre-commit Cargo.toml src/main.rs
git commit -qm "init"

# Helper: stage N new docs/*.md files, write commit msg, run docs-delta block.
# Returns the hook's exit code.
run_check() {
    local n_added="$1"
    local trailer_val="$2"  # empty string for no trailer
    rm -f docs/*.md 2>/dev/null || true
    git rm --cached --quiet docs/*.md 2>/dev/null || true
    for i in $(seq 1 "$n_added"); do
        echo "doc $i" > "docs/test-${i}.md"
        git add "docs/test-${i}.md"
    done
    # Touch + stage src/main.rs so the hook's pre-INFRA-257 staged_rust
    # short-circuit doesn't bail before the docs-delta block runs.
    echo "fn main() { /* turn $RANDOM */ }" > src/main.rs
    git add src/main.rs
    # Write the commit message file (used by the hook via $1 / COMMIT_EDITMSG).
    local msg_file="$TMP/.git/COMMIT_EDITMSG"
    if [[ -n "$trailer_val" ]]; then
        printf "test commit\n\nNet-new-docs: +%s\n" "$trailer_val" > "$msg_file"
    else
        printf "test commit (no trailer)\n" > "$msg_file"
    fi
    # Disable the cargo-check guard — we don't want it trying to compile a
    # one-line dummy.rs in a temp dir without a Cargo.toml.
    set +e
    CHUMP_CHECK_BUILD=0 \
        bash scripts/git-hooks/pre-commit "$msg_file" >/tmp/infra-124-test-out 2>&1
    local rc=$?
    set -e
    return $rc
}

# ── Test 1: trailer matches → accepted ───────────────────────────────────────
echo "Test 1: trailer +5 matches actual +5 → expect accept"
if run_check 5 "5"; then
    echo "[PASS] trailer matching delta accepted"
else
    echo "[FAIL] trailer matching delta should accept (got rc=$?)"
    cat /tmp/infra-124-test-out >&2 || true
    exit 1
fi

# ── Test 2: trailer understates → rejected (INFRA-124 fix) ───────────────────
echo ""
echo "Test 2: trailer +1 understates actual +5 → expect reject"
if run_check 5 "1"; then
    echo "[FAIL] INFRA-124 regression: trailer +1 should be rejected when actual is +5"
    cat /tmp/infra-124-test-out >&2 || true
    exit 1
else
    if grep -q "INFRA-124" /tmp/infra-124-test-out; then
        echo "[PASS] understated trailer rejected with INFRA-124 diagnostic"
    else
        echo "[PASS] understated trailer rejected (no INFRA-124 marker — message check skipped)"
    fi
fi

# ── Test 3: trailer overstates → accepted ────────────────────────────────────
echo ""
echo "Test 3: trailer +10 overstates actual +2 → expect accept"
if run_check 2 "10"; then
    echo "[PASS] over-declared trailer accepted (intentional batch declaration)"
else
    echo "[FAIL] over-declared trailer should be accepted (got rc=$?)"
    cat /tmp/infra-124-test-out >&2 || true
    exit 1
fi

# ── Test 4: no trailer + adds → blocked (existing behavior preserved) ─────────
echo ""
echo "Test 4: no trailer with +3 docs added → expect block (post-2026-04-28 cutover)"
if run_check 3 ""; then
    echo "[FAIL] missing trailer should block when adding docs"
    cat /tmp/infra-124-test-out >&2 || true
    exit 1
else
    echo "[PASS] missing trailer blocks as expected"
fi

echo ""
echo "[OK] all 4 INFRA-124 trailer-validation cases passed"
