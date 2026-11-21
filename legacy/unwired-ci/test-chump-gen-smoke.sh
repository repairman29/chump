#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# test-chump-gen-smoke.sh — INFRA-593: smoke test for `chump gen`.
#
# Verifies that `chump gen "add comment"` against a fixture Rust repo:
#   1. Exits 0.
#   2. Lands a git commit whose message contains "chump gen: add comment".
#   3. The target file contains the prepended chump-gen comment.
#
# Uses CHUMP_GEN_STUB_FILE to skip the real LLM call (no API key needed).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$(dirname "$0")/lib/discover-chump-bin.sh"


PASS=0
FAIL=0

check() {
    local label="$1"
    local ok="$2"    # "ok" = pass, anything else printed as failure detail
    if [[ "$ok" == "ok" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label — $ok" >&2
        FAIL=$((FAIL + 1))
    fi
}

# ── 1. Set up a throwaway fixture Rust repo ────────────────────────────────────
FIXTURE_DIR="$(mktemp -d -t chump-gen-smoke.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

echo "[gen-smoke] fixture dir: $FIXTURE_DIR"

mkdir -p "$FIXTURE_DIR/src"

cat > "$FIXTURE_DIR/Cargo.toml" <<'TOML'
[package]
name = "gen-smoke-fixture"
version = "0.1.0"
edition = "2021"
TOML

cat > "$FIXTURE_DIR/src/main.rs" <<'RUST'
fn main() {
    println!("hello");
}
RUST

git -C "$FIXTURE_DIR" init -q
git -C "$FIXTURE_DIR" config user.email "smoke@test.local"
git -C "$FIXTURE_DIR" config user.name  "Smoke Test"
git -C "$FIXTURE_DIR" add --all
git -C "$FIXTURE_DIR" commit -q -m "initial fixture"

# ── 2. Run `chump gen "add comment"` in stub mode ─────────────────────────────
echo "[gen-smoke] running: chump gen 'add comment' --work-dir <fixture>"

GEN_OUTPUT="$(
    CHUMP_GEN_STUB_FILE="src/main.rs" \
        "$CHUMP_BIN" gen "add comment" --work-dir "$FIXTURE_DIR" 2>&1
)"
GEN_EXIT=$?
echo "$GEN_OUTPUT" | sed 's/^/    /'

check "chump gen exits 0" "$([ "$GEN_EXIT" -eq 0 ] && echo ok || echo "exit code $GEN_EXIT")"

# ── 3. Assert a commit landed with the right message ─────────────────────────
LAST_MSG="$(git -C "$FIXTURE_DIR" log --oneline -1 2>/dev/null || echo '')"
echo "[gen-smoke] last commit: $LAST_MSG"

if echo "$LAST_MSG" | grep -q "chump gen: add comment"; then
    check "commit message contains 'chump gen: add comment'" "ok"
else
    check "commit message contains 'chump gen: add comment'" "got: $LAST_MSG"
fi

# ── 4. Assert the file was modified ───────────────────────────────────────────
FILE_HEAD="$(head -1 "$FIXTURE_DIR/src/main.rs")"
if echo "$FILE_HEAD" | grep -q "// chump-gen:"; then
    check "src/main.rs starts with chump-gen comment" "ok"
else
    check "src/main.rs starts with chump-gen comment" "got: $FILE_HEAD"
fi

# ── 5. Summary ────────────────────────────────────────────────────────────────
echo ""
if [[ $FAIL -gt 0 ]]; then
    echo "[gen-smoke] FAILED: $FAIL check(s) failed, $PASS passed" >&2
    exit 1
fi
echo "[gen-smoke] All $PASS checks passed"
