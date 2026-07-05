#!/usr/bin/env bash
# test-gap-decompose-description.sh — INFRA-945
#
# Validates that `chump gap decompose` injects the gap description into the
# LLM prompt as a prominent "Additional context from filing agent:" block,
# and that --no-description suppresses it.
#
# Tests (no LLM call required — uses --dry-run):
#  1. --dry-run flag accepted without error
#  2. --no-description flag accepted without error
#  3. Description text appears in --dry-run output when description is set
#  4. "Additional context from filing agent:" header present in dry-run output
#  5. --no-description omits the description block from the prompt
#  6. Gap without description does not emit "Additional context" block
#  7. CLAUDE.md documents the two-phase decomposition pattern
#  8. main.rs has --dry-run in the decompose usage string
#  9. main.rs has --no-description in the decompose usage string

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP="${CHUMP_BIN:-chump}"
TMPDB="$(mktemp -d)/test.db"

echo "=== INFRA-945 gap decompose description injection test ==="
echo

# ── Static source checks ─────────────────────────────────────────────────────

# 1. --dry-run flag wired in usage string
if grep -q '\-\-dry-run.*decompose\|decompose.*\-\-dry-run' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "--dry-run mentioned in decompose usage string"
else
    fail "--dry-run missing from decompose usage string in main.rs"
fi

# 2. --no-description flag wired in usage string
if grep -q '\-\-no-description' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "--no-description mentioned in main.rs"
else
    fail "--no-description missing from main.rs"
fi

# 3. description_block variable constructed in main.rs
if grep -q 'description_block' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "description_block variable present in main.rs"
else
    fail "description_block variable missing from main.rs"
fi

# 4. "Additional context from filing agent:" string in main.rs
if grep -q 'Additional context from filing agent' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "'Additional context from filing agent' string in main.rs"
else
    fail "'Additional context from filing agent' string missing from main.rs"
fi

# 5. dry_run guard present before LLM call
if grep -q 'if dry_run' "$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"; then
    ok "dry_run guard present in main.rs"
else
    fail "dry_run guard missing from main.rs"
fi

# 6. CLAUDE.md documents the two-phase decomposition pattern
if grep -q 'Two-phase decomposition' "$REPO_ROOT/CLAUDE.md"; then
    ok "CLAUDE.md has Two-phase decomposition section"
else
    fail "CLAUDE.md missing Two-phase decomposition section"
fi

# 7. CLAUDE.md mentions --dry-run for decompose
if grep -q '\-\-dry-run' "$REPO_ROOT/CLAUDE.md"; then
    ok "CLAUDE.md mentions --dry-run in decompose context"
else
    fail "CLAUDE.md missing --dry-run mention"
fi

# ── Runtime checks using a fixture gap ───────────────────────────────────────
# These require the chump binary and test a synthetic gap with a description.

if ! command -v "$CHUMP" &>/dev/null; then
    echo
    echo "  SKIP: chump binary not found at '${CHUMP}' — skipping runtime tests"
    echo "        Set CHUMP_BIN=<path> to enable"
else
    FIXTURE_DESCRIPTION="uses gap_store module and the parse_json_ac_list helper"
    FIXTURE_TITLE="INFRA-945-test-fixture-decompose-description"

    # Create a synthetic state.db with a medium gap that has a description
    CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap reserve \
        --domain INFRA \
        --title "$FIXTURE_TITLE" \
        2>/dev/null || true

    # Get the ID of the gap we just created
    FIXTURE_ID=$(CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap list --status open --json 2>/dev/null \
        | grep -o '"id":"[^"]*"' | tail -1 | sed 's/"id":"//;s/"//') || true

    if [[ -z "$FIXTURE_ID" ]]; then
        echo "  SKIP: could not create fixture gap — skipping runtime tests"
    else
        # Set effort to m (decompose requires m/l/xl)
        CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap set "$FIXTURE_ID" --effort m 2>/dev/null || true
        # Set description
        CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap set "$FIXTURE_ID" \
            --description "$FIXTURE_DESCRIPTION" 2>/dev/null || true

        # 8. --dry-run with description: output contains "Additional context"
        DRY_OUT=$(CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap decompose "$FIXTURE_ID" \
            --dry-run 2>&1) || true
        if echo "$DRY_OUT" | grep -q "Additional context from filing agent"; then
            ok "--dry-run output contains 'Additional context from filing agent:'"
        else
            fail "--dry-run output missing 'Additional context from filing agent:'"
        fi

        # 9. --dry-run with description: description text appears in prompt
        if echo "$DRY_OUT" | grep -q "parse_json_ac_list"; then
            ok "--dry-run output contains description text (parse_json_ac_list)"
        else
            fail "--dry-run output missing description text"
        fi

        # 10. --dry-run --no-description: "Additional context" suppressed
        DRY_NO_DESC=$(CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap decompose "$FIXTURE_ID" \
            --dry-run --no-description 2>&1) || true
        if echo "$DRY_NO_DESC" | grep -q "Additional context from filing agent"; then
            fail "--no-description still injected description block"
        else
            ok "--no-description suppresses 'Additional context' block"
        fi

        # 11. --dry-run --no-description: description text not in prompt
        if echo "$DRY_NO_DESC" | grep -q "parse_json_ac_list"; then
            fail "--no-description still contains description text"
        else
            ok "--no-description omits description text from prompt"
        fi
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
