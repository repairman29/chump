#!/usr/bin/env bash
# scripts/ci/test-post-rebase-verify.sh — INFRA-1526
#
# Smoke tests for scripts/coord/post-rebase-verify.sh.
# Sets up synthetic two-branch git repos in temp dirs, runs the verifier,
# and asserts exit codes + ambient event emission.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/../coord/post-rebase-verify.sh"

PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# ── Helpers ───────────────────────────────────────────────────────────────────

make_repo() {
    local repo="$1"
    git init -q "$repo"
    git -C "$repo" config user.email "test@chump"
    git -C "$repo" config user.name  "chump-test"
    printf 'base content\n' > "$repo/base.txt"
    git -C "$repo" add base.txt
    git -C "$repo" commit -q -m "initial"
    git -C "$repo" branch -M main
}

# run_verify <repo> <pre_sha> [extra env args...]
# Runs the verifier script from inside the repo (so git commands resolve correctly).
run_verify() {
    local repo="$1" pre="$2"
    shift 2
    (cd "$repo" && CHUMP_REBASE_UPSTREAM=main PRE_REBASE_SHA="$pre" \
        CHUMP_REPO_ROOT="$repo" bash "$VERIFY_SCRIPT" "$@")
}

# ── Test 1: clean rebase — verifier exits 0 ───────────────────────────────────
echo "Test 1: clean rebase (no hunk drop)"
{
    TMP="$(mktemp -d)"

    make_repo "$TMP"

    git -C "$TMP" checkout -q -b feature
    python3 -c "print('\n'.join(f'line {i}' for i in range(60)))" > "$TMP/feature.rs"
    git -C "$TMP" add feature.rs
    git -C "$TMP" commit -q -m "add feature.rs (+60 lines)"
    FEATURE_TIP="$(git -C "$TMP" rev-parse HEAD)"

    git -C "$TMP" checkout -q main
    printf 'main extra\n' >> "$TMP/base.txt"
    git -C "$TMP" commit -q -m "main advance" base.txt

    git -C "$TMP" checkout -q feature
    git -C "$TMP" rebase main -q 2>/dev/null

    if run_verify "$TMP" "$FEATURE_TIP" >/dev/null 2>&1; then
        ok "exit 0 on clean rebase"
    else
        fail "exit non-zero on clean rebase (unexpected)"
    fi

    rm -rf "$TMP"
}

# ── Test 2: hunk drop via -X theirs — verifier exits 1 and emits event ────────
echo "Test 2: hunk drop (simulated via -X theirs)"
{
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/.chump-locks"

    make_repo "$TMP"

    git -C "$TMP" checkout -q -b feature
    python3 -c "print('\n'.join(f'fn line_{i}() {{}}' for i in range(60)))" > "$TMP/feature.rs"
    git -C "$TMP" add feature.rs
    git -C "$TMP" commit -q -m "add feature.rs (+60 lines)"
    FEATURE_TIP="$(git -C "$TMP" rev-parse HEAD)"

    # Advance main with a conflicting version — ensures a real conflict on rebase
    git -C "$TMP" checkout -q main
    printf 'fn main_override() {}\n' > "$TMP/feature.rs"
    git -C "$TMP" add feature.rs
    git -C "$TMP" commit -q -m "main stomps feature.rs"

    # -X ours in rebase context takes the UPSTREAM (main) version, dropping the
    # 60-line feature content — this is what the rust-main-append merge driver
    # did when it fell back to "take-ours" on non-pure-append conflicts.
    git -C "$TMP" checkout -q feature
    git -C "$TMP" rebase -X ours main -q 2>/dev/null || true

    if run_verify "$TMP" "$FEATURE_TIP" 2>/dev/null; then
        fail "exit 0 on dropped hunk (expected exit 1)"
    else
        ok "exit 1 on dropped hunk"
    fi

    if [[ -f "$TMP/.chump-locks/ambient.jsonl" ]] && \
       grep -q '"kind":"rebase_hunk_dropped"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
        ok "rebase_hunk_dropped event emitted"
    else
        fail "rebase_hunk_dropped event NOT emitted"
    fi

    rm -rf "$TMP"
}

# ── Test 3: small file below threshold — verifier exits 0 ────────────────────
echo "Test 3: small file below threshold (no alert)"
{
    TMP="$(mktemp -d)"

    make_repo "$TMP"

    git -C "$TMP" checkout -q -b feature
    printf 'fn small() {}\n%.0s' {1..10} > "$TMP/small.rs"
    git -C "$TMP" add small.rs
    git -C "$TMP" commit -q -m "add small.rs (+10 lines)"
    FEATURE_TIP="$(git -C "$TMP" rev-parse HEAD)"

    git -C "$TMP" checkout -q main
    printf 'fn override() {}\n' > "$TMP/small.rs"
    git -C "$TMP" add small.rs
    git -C "$TMP" commit -q -m "main stomps small.rs"

    git -C "$TMP" checkout -q feature
    git -C "$TMP" rebase -X theirs main -q 2>/dev/null || true

    if run_verify "$TMP" "$FEATURE_TIP" >/dev/null 2>&1; then
        ok "exit 0 on small-file drop (below 50-line threshold)"
    else
        fail "exit 1 on small-file drop (threshold should not fire)"
    fi

    rm -rf "$TMP"
}

# ── Test 4: ORIG_HEAD auto-detection — verifier uses git-set ORIG_HEAD ────────
echo "Test 4: ORIG_HEAD auto-detection (no explicit PRE_REBASE_SHA)"
{
    TMP="$(mktemp -d)"

    make_repo "$TMP"

    git -C "$TMP" checkout -q -b feature
    python3 -c "print('\n'.join(f'fn func_{i}() {{}}' for i in range(60)))" > "$TMP/funcs.rs"
    git -C "$TMP" add funcs.rs
    git -C "$TMP" commit -q -m "add funcs.rs"

    git -C "$TMP" checkout -q main
    printf 'extra\n' >> "$TMP/base.txt"
    git -C "$TMP" commit -q -m "main advance" base.txt

    git -C "$TMP" checkout -q feature
    git -C "$TMP" rebase main -q 2>/dev/null

    # Run without PRE_REBASE_SHA — verifier must pick up ORIG_HEAD from the repo
    if (cd "$TMP" && CHUMP_REBASE_UPSTREAM=main CHUMP_REPO_ROOT="$TMP" \
            bash "$VERIFY_SCRIPT" >/dev/null 2>&1); then
        ok "exit 0 with ORIG_HEAD auto-detection"
    else
        fail "exit non-zero with ORIG_HEAD auto-detection"
    fi

    rm -rf "$TMP"
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
