#!/usr/bin/env bash
# test-post-rebase-verify.sh — INFRA-1526
#
# Static + behavioral smoke tests for scripts/ci/post-rebase-verify.sh.
# Does not require a live git remote or GitHub access.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/post-rebase-verify.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── Existence + permissions ───────────────────────────────────────────────────

[[ -f "$SCRIPT" ]] || fail "script missing: $SCRIPT"
[[ -x "$SCRIPT" ]] || fail "script not executable: $SCRIPT"
ok "post-rebase-verify.sh exists and is executable"

# ── Safety: no ORIG_HEAD → exit 0 (not an error) ─────────────────────────────

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Run in an empty dir with no .git — should exit 0 with skip message
(
    cd "$tmp_dir"
    git init --quiet
    output="$("$SCRIPT" 2>&1 || true)"
    echo "$output" | grep -q "no .git/ORIG_HEAD" || \
        echo "$output" | grep -q "skipping" || \
        { echo "Expected skip message, got: $output"; exit 1; }
) || fail "should exit 0 and skip when no .git/ORIG_HEAD present"
ok "exits 0 and skips gracefully when .git/ORIG_HEAD is absent"

# ── Structural guards ─────────────────────────────────────────────────────────

# Must read ORIG_HEAD by default
grep -q 'ORIG_HEAD' "$SCRIPT" || fail "script does not reference ORIG_HEAD"
ok "references ORIG_HEAD"

# Must emit rebase_hunk_dropped event
grep -q 'rebase_hunk_dropped' "$SCRIPT" || fail "missing rebase_hunk_dropped event kind"
ok "emits kind=rebase_hunk_dropped"

# Must have a scanner-anchor comment for the event kind (INFRA-register-without-emit guard)
grep -q '# scanner-anchor: "kind":"rebase_hunk_dropped"' "$SCRIPT" || \
    fail "missing scanner-anchor comment for rebase_hunk_dropped"
ok "scanner-anchor comment present"

# Must use --numstat for line-level counting (not just --stat)
grep -q '\-\-numstat' "$SCRIPT" || fail "should use git diff --numstat for per-line counts"
ok "uses git diff --numstat for per-file line counts"

# Must accept --base flag
grep -q '\-\-base' "$SCRIPT" || fail "missing --base flag"
ok "accepts --base flag"

# Must accept --ambient flag
grep -q '\-\-ambient' "$SCRIPT" || fail "missing --ambient flag"
ok "accepts --ambient flag"

# Must exit non-zero on drop detection (exit 1 in the drop path)
grep -q '^exit 1' "$SCRIPT" || fail "missing exit 1 in drop-detected path"
ok "exits non-zero when hunk drop detected"

# Must respect CHUMP_REBASE_DROP_LINES env var for threshold tuning
grep -q 'CHUMP_REBASE_DROP_LINES' "$SCRIPT" || fail "missing CHUMP_REBASE_DROP_LINES support"
ok "threshold tunable via CHUMP_REBASE_DROP_LINES"

# ── Behavioral smoke: simulated hunk drop ────────────────────────────────────
#
# Set up two synthetic commits:
#   orig_head  = branch tip before rebase: adds 60 lines to src/main.rs
#   rebased    = branch tip after rebase: src/main.rs has 0 additions (dropped)
#
# We simulate this by:
#   1. Creating a bare repo with "main" (the base)
#   2. Making a feature commit that adds >50 lines (ORIG_HEAD)
#   3. Rebasing is simulated by creating a NEW commit with 0 lines for that file
#   4. Calling the script with explicit --orig-head and --base pointing at the synthetic shas

smoke_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir" "$smoke_dir"' EXIT

(
    cd "$smoke_dir"
    git init --quiet
    git config user.email "test@chump"
    git config user.name "Test"

    # Base commit (simulates origin/main)
    echo "fn main() {}" > src_main_rs
    git add src_main_rs
    git commit --quiet -m "base"
    BASE_SHA="$(git rev-parse HEAD)"

    # Feature commit with >50 added lines (simulates ORIG_HEAD before rebase)
    printf '%s\n' $(seq 1 60 | xargs -I{} echo "line{}") >> src_main_rs
    git add src_main_rs
    git commit --quiet -m "feature: add 60 lines"
    ORIG_HEAD="$(git rev-parse HEAD)"

    # Simulate rebase: reset to base, add an unrelated file only (src/main.rs dropped)
    git reset --quiet --hard "$BASE_SHA"
    echo "other content" > other_file
    git add other_file
    git commit --quiet -m "rebased (main.rs silently dropped)"
    REBASED_HEAD="$(git rev-parse HEAD)"

    # Write a fake ORIG_HEAD to .git/ORIG_HEAD
    echo "$ORIG_HEAD" > .git/ORIG_HEAD

    # The "base ref" for this test is the BASE_SHA commit
    # We can't use "origin/main" in a bare repo, so pass --base directly.
    # We'll use the base SHA directly as a ref.

    AMBIENT_LOG="$(mktemp)"
    # Drop threshold = 50; file had 60 additions in original, 0 in rebased.
    # Script should detect the drop and exit 1.
    if CHUMP_REBASE_DROP_LINES=50 \
        "$SCRIPT" \
            --repo "$smoke_dir" \
            --orig-head "$ORIG_HEAD" \
            --base "$BASE_SHA" \
            --ambient "$AMBIENT_LOG" 2>/dev/null; then
        echo "FAIL: expected exit 1 for drop scenario, got exit 0"
        exit 1
    fi

    # Ambient log should have the event
    grep -q '"kind":"rebase_hunk_dropped"' "$AMBIENT_LOG" || {
        echo "FAIL: ambient log missing rebase_hunk_dropped event"
        cat "$AMBIENT_LOG"
        exit 1
    }

    # Event must include file and lines_dropped fields
    grep '"lines_dropped"' "$AMBIENT_LOG" > /dev/null || {
        echo "FAIL: ambient event missing lines_dropped field"
        exit 1
    }

    rm -f "$AMBIENT_LOG"
) || fail "behavioral smoke: hunk-drop scenario did not exit 1 or did not emit event"
ok "behavioral smoke: detects hunk drop, exits 1, emits rebase_hunk_dropped event"

# ── Behavioral smoke: clean rebase → exit 0 ──────────────────────────────────

(
    cd "$(mktemp -d)"
    git init --quiet
    git config user.email "test@chump"
    git config user.name "Test"

    echo "fn main() {}" > src_main_rs
    git add src_main_rs
    git commit --quiet -m "base"
    BASE_SHA="$(git rev-parse HEAD)"

    # Feature commit
    printf '%s\n' $(seq 1 60 | xargs -I{} echo "line{}") >> src_main_rs
    git add src_main_rs
    git commit --quiet -m "feature"
    ORIG_HEAD="$(git rev-parse HEAD)"

    # Simulate a clean rebase: same file, same lines
    git reset --quiet --hard "$BASE_SHA"
    printf '%s\n' $(seq 1 60 | xargs -I{} echo "line{}") >> src_main_rs
    git add src_main_rs
    git commit --quiet -m "rebased cleanly"

    echo "$ORIG_HEAD" > .git/ORIG_HEAD

    AMBIENT_LOG="$(mktemp)"
    CHUMP_REBASE_DROP_LINES=50 \
        "$SCRIPT" \
            --repo "$(pwd)" \
            --orig-head "$ORIG_HEAD" \
            --base "$BASE_SHA" \
            --ambient "$AMBIENT_LOG" 2>/dev/null || {
        echo "FAIL: expected exit 0 for clean rebase, got non-zero"
        exit 1
    }
    grep -q 'rebase_hunk_dropped' "$AMBIENT_LOG" && {
        echo "FAIL: should not emit rebase_hunk_dropped for clean rebase"
        exit 1
    }
    rm -f "$AMBIENT_LOG"
) || fail "behavioral smoke: clean rebase should exit 0 without event"
ok "behavioral smoke: clean rebase exits 0, no event emitted"

# ── EVENT_REGISTRY registration ───────────────────────────────────────────────

ER="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q 'kind: rebase_hunk_dropped' "$ER" || \
    fail "EVENT_REGISTRY missing rebase_hunk_dropped entry"
ok "EVENT_REGISTRY registers rebase_hunk_dropped"

# ── bot-merge.sh wiring ───────────────────────────────────────────────────────

BM="$REPO_ROOT/scripts/coord/bot-merge.sh"
grep -q 'post-rebase-verify.sh' "$BM" || \
    fail "bot-merge.sh does not invoke post-rebase-verify.sh"
grep -q 'INFRA-1526' "$BM" || \
    fail "bot-merge.sh missing INFRA-1526 gap reference in rebase section"
ok "bot-merge.sh wired to post-rebase-verify.sh"

echo ""
echo "All post-rebase-verify checks passed."
