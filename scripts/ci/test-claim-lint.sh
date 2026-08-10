#!/usr/bin/env bash
# CREDIBLE-208 AC5: fixture PRs for both the grounded and ungrounded (bounce)
# claim-lint paths. Builds a throwaway git repo, seeds a diff, and asserts:
#   - a commit whose Files-Touched/Symbols-Touched/Tests-Run claims all
#     appear in the diff grounds clean (exit 0)
#   - a commit that additionally claims a symbol NOT in the diff bounces
#     (exit 1) and names the specific ungrounded claim
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-claim-lint] building chump binary..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FIXTURE_REPO="$TMPDIR_TEST/fixture-repo"
mkdir -p "$FIXTURE_REPO"
cd "$FIXTURE_REPO"
git init -q
git config user.email "test@example.com"
git config user.name "claim-lint-fixture"

mkdir -p src
cat > src/foo.rs <<'EOF'
pub fn placeholder() {}
EOF
git add src/foo.rs
git commit -q -m "seed"

export CHUMP_AMBIENT_LOG="$TMPDIR_TEST/ambient.jsonl"
export CHUMP_REPO_ROOT="$FIXTURE_REPO"

# ── Path 1: grounded claims — all named files/symbols/tests are in the diff ──
cat > src/foo.rs <<'EOF'
pub fn placeholder() {}

pub fn run_baz() {
    // does the thing
}

#[test]
fn test_baz_works() {
    assert!(true);
}
EOF
git add src/foo.rs

MSG_FILE_1="$TMPDIR_TEST/msg1.txt"
cat > "$MSG_FILE_1" <<'EOF'
add run_baz

Files-Touched: src/foo.rs
Symbols-Touched: run_baz
Tests-Run: test_baz_works
EOF

set +e
OUTPUT_1="$("$CHUMP_BIN" claim-lint --range HEAD --message-file "$MSG_FILE_1" --model test-model --gap-id CREDIBLE-208 2>&1)"
RC_1=$?
set -e

echo "[test-claim-lint] grounded-path output: $OUTPUT_1"
if [[ $RC_1 -ne 0 ]]; then
    echo "FAIL: grounded claims should exit 0, got $RC_1"
    exit 1
fi
if ! echo "$OUTPUT_1" | grep -qF "clear to ship"; then
    echo "FAIL: expected 'clear to ship' in grounded-path output"
    exit 1
fi

git commit -q -m "grounded commit"

# ── Path 2: ungrounded claim — a symbol not present anywhere in the diff ─────
cat > src/foo.rs <<'EOF'
pub fn placeholder() {}

pub fn run_baz() {
    // does the thing
}

#[test]
fn test_baz_works() {
    assert!(true);
}

pub fn run_qux() {
    // second real change
}
EOF
git add src/foo.rs

MSG_FILE_2="$TMPDIR_TEST/msg2.txt"
cat > "$MSG_FILE_2" <<'EOF'
add run_qux and run_never_written

Files-Touched: src/foo.rs
Symbols-Touched: run_qux, run_never_written
EOF

set +e
OUTPUT_2="$("$CHUMP_BIN" claim-lint --range HEAD --message-file "$MSG_FILE_2" --model test-model --gap-id CREDIBLE-208 2>&1)"
RC_2=$?
set -e

echo "[test-claim-lint] bounce-path output: $OUTPUT_2"
if [[ $RC_2 -ne 1 ]]; then
    echo "FAIL: ungrounded claim should exit 1, got $RC_2"
    exit 1
fi
if ! echo "$OUTPUT_2" | grep -qF "run_never_written"; then
    echo "FAIL: bounce output must name the specific ungrounded claim (run_never_written)"
    exit 1
fi
if ! echo "$OUTPUT_2" | grep -qF "BOUNCE"; then
    echo "FAIL: expected 'BOUNCE' marker in bounce-path output"
    exit 1
fi

# ── Ambient emission sanity: two claim_lint_result events landed ────────────
if [[ ! -f "$CHUMP_AMBIENT_LOG" ]]; then
    echo "FAIL: expected ambient log at $CHUMP_AMBIENT_LOG"
    exit 1
fi
EVENT_COUNT="$(grep -c '"kind":"claim_lint_result"' "$CHUMP_AMBIENT_LOG" || true)"
if [[ "$EVENT_COUNT" -lt 2 ]]; then
    echo "FAIL: expected >=2 claim_lint_result ambient events, got $EVENT_COUNT"
    exit 1
fi
if ! grep -q '"bust":false' "$CHUMP_AMBIENT_LOG"; then
    echo "FAIL: expected at least one bust:false ambient event"
    exit 1
fi
if ! grep -q '"bust":true' "$CHUMP_AMBIENT_LOG"; then
    echo "FAIL: expected at least one bust:true ambient event"
    exit 1
fi

echo "[test-claim-lint] PASS — grounded path clears, ungrounded path bounces with named claim, ambient emitted"
