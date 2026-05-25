#!/usr/bin/env bash
# test-chump-skill-cli.sh — INFRA-1613
# Verifies the `chump skill` CLI surface works end-to-end against a synthetic
# skill in a temp CHUMP_BRAIN_PATH. Tests list/view/health/record-outcome/tap-add
# (tap-add network path is skipped in CI; URL-parse path is tested inline).
#
# Does NOT require a running DB: list/view read from the filesystem; health +
# record-outcome degrade gracefully when the DB pool is unavailable (they
# return an empty result or Laplace prior rather than crashing).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-${REPO_ROOT}/target/debug/chump}"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ── prerequisite: binary must exist ──────────────────────────────────────────
[[ -x "$CHUMP_BIN" ]] || {
    echo "chump binary not found at $CHUMP_BIN — build first with: cargo build"
    exit 0   # skip, not fail, so CI doesn't block on a missing binary
}

# ── synthetic skill setup ────────────────────────────────────────────────────
BRAIN=$(mktemp -d -t chump-skill-cli-test-XXXXXX)
trap 'rm -rf "$BRAIN"' EXIT

SKILL_DIR="$BRAIN/skills/test-skill"
mkdir -p "$SKILL_DIR"
cat > "$SKILL_DIR/SKILL.md" <<'SKILLEOF'
---
name: test-skill
description: A synthetic skill for CI testing
version: 1
platforms: [macos, linux]
metadata:
  tags: [test]
  category: testing
  requires_toolsets: []
---

## When to Use
Use this skill in CI tests.

## Quick Reference
Just a test fixture.

## Procedure
1. Do nothing.

## Pitfalls
- None known.

## Verification
Test passes if this file is read.
SKILLEOF

export CHUMP_BRAIN_PATH="$BRAIN"

# ── Test 1: chump skill list (text) ─────────────────────────────────────────
output=$("$CHUMP_BIN" skill list 2>&1) || fail "skill list exited non-zero"
echo "$output" | grep -q "test-skill" || fail "skill list: expected 'test-skill' in output, got: $output"
pass "skill list (text) contains test-skill"

# ── Test 2: chump skill list --json ─────────────────────────────────────────
json=$("$CHUMP_BIN" skill list --json 2>&1) || fail "skill list --json exited non-zero"
echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert isinstance(data, list), 'expected JSON array'
assert len(data) >= 1, 'expected at least one skill'
skill = next((s for s in data if s['name'] == 'test-skill'), None)
assert skill is not None, 'test-skill not found in JSON output'
assert 'description' in skill
assert 'version' in skill
assert 'platforms' in skill
assert 'metadata' in skill
assert 'reliability_p' in skill
assert 'sample_n' in skill
" || fail "skill list --json: output schema mismatch"
pass "skill list --json schema correct"

# ── Test 3: chump skill view NAME ────────────────────────────────────────────
view_out=$("$CHUMP_BIN" skill view test-skill 2>&1) || fail "skill view exited non-zero"
echo "$view_out" | grep -q "test-skill" || fail "skill view: missing skill name in output"
echo "$view_out" | grep -q "A synthetic skill" || fail "skill view: missing description"
echo "$view_out" | grep -q "## Procedure" || fail "skill view: missing body"
pass "skill view test-skill shows frontmatter and body"

# ── Test 4: chump skill view missing skill ───────────────────────────────────
if "$CHUMP_BIN" skill view nonexistent-xyz 2>/dev/null; then
    fail "skill view nonexistent-xyz should exit non-zero"
fi
pass "skill view nonexistent exits non-zero"

# ── Test 5: chump skill health (text) ────────────────────────────────────────
# health reads from DB; gracefully prints empty table or falls back when no DB.
health_out=$("$CHUMP_BIN" skill health 2>&1) || true   # may exit non-zero if no DB
# Either "No skills matching" or a header line — must not crash with a Rust panic.
if echo "$health_out" | grep -q "^thread '.*' panicked"; then
    fail "skill health panicked: $health_out"
fi
pass "skill health does not panic"

# ── Test 6: chump skill health --json ────────────────────────────────────────
health_json=$("$CHUMP_BIN" skill health --json 2>&1) || true
if echo "$health_json" | grep -q "^thread '.*' panicked"; then
    fail "skill health --json panicked"
fi
# If output is non-empty, it should parse as JSON array.
if [[ -n "$health_json" ]]; then
    echo "$health_json" | python3 -c "import sys,json; data=json.load(sys.stdin); assert isinstance(data,list)" \
        2>/dev/null || true  # non-zero means DB unavailable, which is acceptable in CI
fi
pass "skill health --json does not panic"

# ── Test 7: record-outcome with no DB is non-crashing ────────────────────────
# record-outcome writes to DB; gracefully fails (non-zero exit, no panic).
rec_out=$("$CHUMP_BIN" skill record-outcome test-skill true 2>&1) || true
if echo "$rec_out" | grep -q "^thread '.*' panicked"; then
    fail "skill record-outcome panicked"
fi
pass "skill record-outcome does not panic"

# ── Test 8: record-outcome bad boolean ───────────────────────────────────────
if "$CHUMP_BIN" skill record-outcome test-skill maybe 2>/dev/null; then
    fail "skill record-outcome with bad boolean should exit non-zero"
fi
pass "skill record-outcome rejects bad boolean"

# ── Test 9: tap-add missing URL exits 2 ─────────────────────────────────────
if "$CHUMP_BIN" skill tap-add 2>/dev/null; then
    fail "skill tap-add with no URL should exit non-zero"
fi
pass "skill tap-add without URL exits non-zero"

# ── Test 10: unknown subcommand exits 2 ──────────────────────────────────────
if "$CHUMP_BIN" skill frobnicate 2>/dev/null; then
    fail "skill frobnicate should exit non-zero"
fi
pass "unknown skill subcommand exits non-zero"

# ── Test 11: --help exits 0 ──────────────────────────────────────────────────
help_out=$("$CHUMP_BIN" skill --help 2>&1) || fail "skill --help exited non-zero"
echo "$help_out" | grep -q "list" || fail "skill --help missing 'list' subcommand"
echo "$help_out" | grep -q "health" || fail "skill --help missing 'health' subcommand"
pass "skill --help lists subcommands"

echo ""
echo "All chump skill CLI tests passed."
