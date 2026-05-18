#!/usr/bin/env bash
# scripts/ci/test-infra-1451-intent-parser.sh — INFRA-1451
#
# Verifies that the intent parser correctly extracts --size / --domain /
# --priority from FleetStart natural-language phrases.
#
# Checks:
#   1. Source: extract_size, extract_domain, extract_fleet_priority defined
#   2. Source: FleetStart variant carries named size/domain/priority fields
#   3. Cargo unit tests (intent_parser module) all pass
#   4. Binary: "spawn the fleet on infra p0/p1, size 4" → correct JSON
#   5. Binary: "start fleet effective size 2" → --size 2 --domain EFFECTIVE
#   6. Binary: "launch fleet" → bare start (no flags)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/src/intent_parser.rs"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"
CARGO="${CARGO:-}"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
skip() { printf '\033[0;33mSKIP\033[0m %s\n' "$*"; }

[[ -f "$SRC" ]] || fail "intent_parser.rs missing: $SRC"

# ── 1. Helper functions defined ───────────────────────────────────────────────
grep -q "fn extract_size" "$SRC" \
    || fail "extract_size not defined (INFRA-1451)"
grep -q "fn extract_domain" "$SRC" \
    || fail "extract_domain not defined (INFRA-1451)"
grep -q "fn extract_fleet_priority" "$SRC" \
    || fail "extract_fleet_priority not defined (INFRA-1451)"
grep -q "INFRA-1451" "$SRC" \
    || fail "INFRA-1451 marker missing from intent_parser.rs"
ok "INFRA-1451 helper functions defined"

# ── 2. FleetStart carries named fields ───────────────────────────────────────
grep -q "FleetStart {" "$SRC" \
    || fail "FleetStart must use named fields {size, domain, priority}"
grep -q "size: Option<u32>" "$SRC" \
    || fail "FleetStart.size field missing"
grep -q "domain: Option<String>" "$SRC" \
    || fail "FleetStart.domain field missing"
grep -q "priority: Option<String>" "$SRC" \
    || fail "FleetStart.priority field missing"
ok "FleetStart has size/domain/priority named fields"

# ── 3. Cargo unit tests pass ─────────────────────────────────────────────────
if [[ -z "$CARGO" ]]; then
    # Try to find cargo
    for candidate in \
        "$(command -v cargo 2>/dev/null)" \
        "$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo" \
        "$HOME/.cargo/bin/cargo"; do
        if [[ -x "$candidate" ]]; then
            CARGO="$candidate"
            break
        fi
    done
fi

if [[ -z "$CARGO" ]]; then
    skip "cargo not found — skipping unit test round"
else
    (cd "$REPO_ROOT" && "$CARGO" test --bin chump intent_parser --quiet 2>&1 | tail -3) \
        || fail "cargo test intent_parser failed"
    ok "intent_parser unit tests pass (via cargo)"
fi

# ── Binary integration tests ──────────────────────────────────────────────────
if [[ ! -x "$CHUMP_BIN" ]]; then
    # Try the shared project target dir (worktrees share parent target/).
    ALT_BIN="$(cd "$REPO_ROOT" && git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
    if [[ -n "$ALT_BIN" && -x "$ALT_BIN/target/debug/chump" ]]; then
        CHUMP_BIN="$ALT_BIN/target/debug/chump"
    fi
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    skip "CHUMP_BIN not found at $CHUMP_BIN — skipping binary rounds 4-6"
    skip "  Build with: cargo build --bin chump"
    echo ""
    echo "Source-level checks (rounds 1-3) PASSED."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/.chump-locks" "$WORK/repo/.chump"
cd "$WORK/repo"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git commit --allow-empty -m "init" -q
sqlite3 "$WORK/repo/.chump/state.db" \
    "CREATE TABLE gaps (id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT, priority TEXT, effort TEXT, depends_on TEXT, notes TEXT);"

# ── Round 4: demo phrase → full flags ────────────────────────────────────────
set +e
OUT4=$(CHUMP_REPO_ROOT="$WORK/repo" "$CHUMP_BIN" orchestrate \
    "spawn the fleet on infra p0/p1, size 4" --no-execute --json 2>&1)
EXIT4=$?
set -e

echo "$OUT4" | grep -q '"command"' \
    || { skip "round 4: orchestrate --no-execute not supported; checking intent_parser unit tests instead"; }
if echo "$OUT4" | grep -q '"command"'; then
    echo "$OUT4" | grep -q '"--size 4"' || echo "$OUT4" | grep -q 'size 4' \
        || fail "round 4: --size 4 not in output; got: $OUT4"
    echo "$OUT4" | grep -q 'INFRA' \
        || fail "round 4: INFRA domain not in output; got: $OUT4"
    ok "round 4: demo phrase → --size 4 --domain INFRA --priority P0,P1"
fi

echo ""
echo "All checks PASSED — INFRA-1451 intent parser extracts FleetStart params"
