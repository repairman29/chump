#!/usr/bin/env bash
# test-gen-cost-summary.sh — INFRA-643: cost summary printed by chump gen.
#
# Verifies:
#   1. `chump gen` prints a "completed in Xs — N tokens (~$Y Model)" line.
#   2. `chump gen --quiet` suppresses the summary line.
#
# Uses CHUMP_GEN_STUB_FILE to skip the real LLM call (no API key needed).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$(dirname "$0")/lib/discover-chump-bin.sh"


PASS=0
FAIL=0

check() {
    local label="$1"
    local ok="$2"
    if [[ "$ok" == "ok" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label — $ok" >&2
        FAIL=$((FAIL + 1))
    fi
}

# ── Set up throwaway fixture Rust repo ────────────────────────────────────────
FIXTURE_DIR="$(mktemp -d -t chump-gen-cost.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/src"

cat > "$FIXTURE_DIR/Cargo.toml" <<'TOML'
[package]
name = "gen-cost-fixture"
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

# ── 1. Default mode — cost summary should appear ──────────────────────────────
echo "[gen-cost-summary] testing default (no --quiet)"

OUTPUT="$(
    CHUMP_GEN_STUB_FILE="src/main.rs" \
        "$CHUMP_BIN" gen "add a comment" --work-dir "$FIXTURE_DIR" 2>&1
)"
echo "$OUTPUT" | sed 's/^/    /'

if echo "$OUTPUT" | grep -qE "completed in [0-9]+\.[0-9]+s — "; then
    check "cost summary line present" "ok"
else
    check "cost summary line present" "not found in output"
fi

if echo "$OUTPUT" | grep -qE "tokens \(~\\\$[0-9]+\.[0-9]+ "; then
    check "cost summary contains tokens + cost" "ok"
else
    check "cost summary contains tokens + cost" "format mismatch: $OUTPUT"
fi

# ── 2. Quiet mode — cost summary should be suppressed ────────────────────────
echo "[gen-cost-summary] testing --quiet flag"

# Re-init fixture for second run (commit already consumed the file)
git -C "$FIXTURE_DIR" checkout -q HEAD -- src/main.rs 2>/dev/null || true

OUTPUT_QUIET="$(
    CHUMP_GEN_STUB_FILE="src/main.rs" \
        "$CHUMP_BIN" gen "add a comment" --work-dir "$FIXTURE_DIR" --quiet 2>&1
)"
echo "$OUTPUT_QUIET" | sed 's/^/    /'

if echo "$OUTPUT_QUIET" | grep -qE "completed in [0-9]+\.[0-9]+s"; then
    check "--quiet suppresses cost summary" "summary still appeared"
else
    check "--quiet suppresses cost summary" "ok"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $FAIL -gt 0 ]]; then
    echo "[gen-cost-summary] FAILED: $FAIL check(s) failed, $PASS passed" >&2
    exit 1
fi
echo "[gen-cost-summary] All $PASS checks passed"
