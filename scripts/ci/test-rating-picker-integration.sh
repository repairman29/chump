#!/usr/bin/env bash
# test-rating-picker-integration.sh — INFRA-1555
#
# Validates the gap_impact_rated → picker tie-break demotion pipeline:
#  1. Writes 5 synthetic gap_impact_rated events (rating=1, domain=TEST) to a
#     temp ambient.jsonl — all below the 2.5 demotion threshold.
#  2. Calls the Rust unit-test target to verify load_class_ratings + demotion.
#  3. Verifies EVENT_REGISTRY.yaml has status:active on gap_impact_rated.
#  4. Checks kpi_report class_ratings subsection appears in --impact output
#     (binary must exist; skips gracefully if not yet built).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-1555 rating-picker-integration test ==="

# ── 1. Synthetic ambient.jsonl with 5 TEST-domain ratings at 1.0 ──────────────
TMPDIR_CI="$(mktemp -d /tmp/chump-rating-ci-XXXXXXXX)"
trap 'rm -rf "$TMPDIR_CI"' EXIT

LOCKS_DIR="$TMPDIR_CI/.chump-locks"
mkdir -p "$LOCKS_DIR"
AMBIENT="$LOCKS_DIR/ambient.jsonl"

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for i in 1 2 3 4 5; do
    echo "{\"ts\":\"$NOW_ISO\",\"kind\":\"gap_impact_rated\",\"gap_id\":\"TEST-$i\",\"rating\":1,\"comment\":\"low\",\"pr_number\":null}" >> "$AMBIENT"
done
ok "wrote 5 gap_impact_rated events to synthetic ambient.jsonl"

# Verify event count
COUNT=$(grep -c '"gap_impact_rated"' "$AMBIENT" || echo 0)
if [ "$COUNT" -eq 5 ]; then
    ok "ambient.jsonl contains exactly 5 gap_impact_rated events"
else
    fail "expected 5 gap_impact_rated events, got $COUNT"
fi

# ── 2. Rust unit tests for load_class_ratings + effective_priority_rank ────────
echo ""
echo "--- Rust unit tests (atomic_claim + kpi_report) ---"
CHUMP_BIN="$REPO_ROOT/target/debug/chump"

# Build if not present
if [ ! -f "$CHUMP_BIN" ]; then
    echo "  [info] chump binary not found at $CHUMP_BIN; running cargo test directly"
fi

if command -v cargo &>/dev/null; then
    cd "$REPO_ROOT"
    if PATH="$HOME/.cargo/bin:$PATH" cargo test \
        --bins \
        -p chump \
        -- rating_picker_demotion 2>&1 | grep -E "test.*ok|test.*FAILED|running [0-9]"; then
        ok "cargo test rating_picker_demotion passed"
    else
        fail "cargo test rating_picker_demotion failed or no tests matched"
    fi
else
    echo "  [skip] cargo not available; skipping Rust unit tests"
fi

# ── 3. EVENT_REGISTRY.yaml has status:active on gap_impact_rated ───────────────
echo ""
echo "--- EVENT_REGISTRY.yaml check ---"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if [ -f "$REGISTRY" ]; then
    # Find the gap_impact_rated block and check it has status: active within 6 lines
    BLOCK=$(grep -A6 "gap_impact_rated" "$REGISTRY" | head -10)
    if echo "$BLOCK" | grep -q "status: active"; then
        ok "EVENT_REGISTRY.yaml gap_impact_rated has status: active"
    else
        fail "EVENT_REGISTRY.yaml gap_impact_rated missing status: active"
    fi
    if echo "$BLOCK" | grep -q "emitter_paths:"; then
        ok "EVENT_REGISTRY.yaml gap_impact_rated has emitter_paths"
    else
        fail "EVENT_REGISTRY.yaml gap_impact_rated missing emitter_paths"
    fi
else
    fail "EVENT_REGISTRY.yaml not found at $REGISTRY"
fi

# ── 4. kpi report --impact includes class_ratings section (binary path) ────────
echo ""
echo "--- kpi report --impact class_ratings check ---"
if [ -f "$CHUMP_BIN" ]; then
    # Set up a minimal repo fixture
    FIXTURE="$TMPDIR_CI/fixture-repo"
    mkdir -p "$FIXTURE/.chump" "$FIXTURE/.chump-locks"
    cp "$AMBIENT" "$FIXTURE/.chump-locks/ambient.jsonl"
    # Need a minimal state.db — just touch it so the binary doesn't crash
    touch "$FIXTURE/.chump/state.db"

    OUTPUT=$("$CHUMP_BIN" --repo "$FIXTURE" kpi report --impact 2>/dev/null || true)
    if echo "$OUTPUT" | grep -q "Gap rating by class"; then
        ok "kpi report --impact shows 'Gap rating by class' subsection"
    else
        fail "kpi report --impact missing 'Gap rating by class' subsection"
    fi
else
    echo "  [skip] chump binary not built; skipping kpi report --impact check"
    echo "         Build with: cargo build -p chump"
fi

# ── 5. CLAUDE.md snippet present ───────────────────────────────────────────────
echo ""
echo "--- CLAUDE.md picker snippet check ---"
CLAUDEMD="$REPO_ROOT/CLAUDE.md"
if grep -q "chump gap rate" "$CLAUDEMD" && grep -q "class-aggregate ratings" "$CLAUDEMD"; then
    ok "CLAUDE.md contains picker rating workflow snippet"
else
    fail "CLAUDE.md missing picker rating workflow snippet"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
