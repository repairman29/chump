#!/usr/bin/env bash
# scripts/ci/test-orchestrate-session-summary.sh — INFRA-1363
#
# Verifies that `chump orchestrate` emits exactly one kind=orchestrate_session_summary
# event to ambient.jsonl at session end, with the correct field shape.
#
# Strategy: run `chump orchestrate` in stub mode (CHUMP_ORCHESTRATE_STUB=1) with 3
# synthetic intents piped on stdin, then grep the ambient log for the summary event.
#
# Stub mode avoids any real LLM calls so the test works offline and in CI.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-1363 orchestrate_session_summary tests ==="

# ── Source contract checks ────────────────────────────────────────────────────
if grep -q "emit_session_summary" "$REPO_ROOT/src/orchestrate.rs" 2>/dev/null; then
    ok "src/orchestrate.rs defines emit_session_summary"
else
    fail "src/orchestrate.rs missing emit_session_summary function"
fi

if grep -q "orchestrate_session_summary" "$REPO_ROOT/src/orchestrate.rs" 2>/dev/null; then
    ok "src/orchestrate.rs emits orchestrate_session_summary kind"
else
    fail "src/orchestrate.rs missing orchestrate_session_summary emit"
fi

if grep -q "CHUMP_ORCHESTRATE_SESSION_ID" "$REPO_ROOT/src/orchestrate.rs" 2>/dev/null; then
    ok "src/orchestrate.rs reads CHUMP_ORCHESTRATE_SESSION_ID env"
else
    fail "src/orchestrate.rs missing CHUMP_ORCHESTRATE_SESSION_ID support"
fi

if grep -q "exit_reason" "$REPO_ROOT/src/orchestrate.rs" 2>/dev/null; then
    ok "src/orchestrate.rs tracks exit_reason"
else
    fail "src/orchestrate.rs missing exit_reason tracking"
fi

if grep -q "estimate_cost_usd" "$REPO_ROOT/src/orchestrate.rs" 2>/dev/null; then
    ok "src/orchestrate.rs estimates cost_usd"
else
    fail "src/orchestrate.rs missing cost_usd estimation"
fi

if grep -q "orchestrate_session_summary" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" 2>/dev/null; then
    ok "EVENT_REGISTRY.yaml registers orchestrate_session_summary"
else
    fail "EVENT_REGISTRY.yaml missing orchestrate_session_summary"
fi

# ── Unit test assertions (cargo test) ─────────────────────────────────────────
CARGO_OUTPUT=""
if command -v cargo >/dev/null 2>&1 && [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    echo ""
    echo "  [running cargo test orchestrate ...]"
    CARGO_OUTPUT="$(cd "$REPO_ROOT" && cargo test orchestrate 2>&1)" || true
    echo "$CARGO_OUTPUT" | grep -E "^test .* (ok|FAILED|ignored)" | sed 's/^/    /'
fi

# ── Integration smoke: stub session with 3 intents ────────────────────────────
# Resolve binary via shared helper (INFRA-1600 follow-up: honors CARGO_TARGET_DIR).
if [[ -f "$(dirname "$0")/lib/discover-chump-bin.sh" ]]; then
    # shellcheck source=lib/discover-chump-bin.sh disable=SC1091
    source "$(dirname "$0")/lib/discover-chump-bin.sh" 2>/dev/null || true
fi
# Legacy fallback: if helper didn't set CHUMP_BIN (e.g. caller already exported), keep going.
if [[ -z "${CHUMP_BIN:-}" || ! -x "${CHUMP_BIN:-}" ]]; then
    # cargo metadata fallback for worktree case (preserves prior behavior)
    if [[ -z "${CHUMP_BIN:-}" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    fi
    if [[ ! -x "$CHUMP_BIN" ]]; then
        _meta="$(cd "$REPO_ROOT" && cargo metadata --no-deps --format-version 1 2>/dev/null \
            | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null || echo "")"
        if [[ -n "$_meta" && -x "$_meta/debug/chump" ]]; then
            CHUMP_BIN="$_meta/debug/chump"
        else
            CHUMP_BIN="$(command -v chump 2>/dev/null || true)"
        fi
    fi
fi

if [[ -x "$CHUMP_BIN" ]]; then
    echo ""
    echo "  [running stub session with 3 intents ...]"
    TMP="$(mktemp -d -t orchestrate-ci.XXXXXX)"
    trap 'rm -rf "$TMP"' EXIT
    LOCK_DIR="$TMP/.chump-locks"
    mkdir -p "$LOCK_DIR"
    AMBIENT="$LOCK_DIR/ambient.jsonl"

    # Seed a minimal docs/ROADMAP.md and CLAUDE.md so doctrine loading doesn't error
    mkdir -p "$TMP/docs"
    echo "# Roadmap" > "$TMP/docs/ROADMAP.md"
    echo "# CLAUDE.md" > "$TMP/CLAUDE.md"

    SESSION_ID="ci-test-1363-$$"

    # Pipe 3 intents then EOF
    printf 'spawn fleet on infra p0\nwhat is mission grade\nstatus\n' \
      | CHUMP_ORCHESTRATE_STUB=1 \
        CHUMP_ORCHESTRATE_SESSION_ID="$SESSION_ID" \
        CHUMP_AMBIENT_IN_PROMPT="$AMBIENT" \
        "$CHUMP_BIN" orchestrate \
        2>&1 >/dev/null || true

    if [[ -f "$AMBIENT" ]]; then
        SUMMARY_COUNT="$(grep '"orchestrate_session_summary"' "$AMBIENT" 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$SUMMARY_COUNT" -eq 1 ]]; then
            ok "exactly one orchestrate_session_summary event emitted"
        else
            fail "expected 1 orchestrate_session_summary, got $SUMMARY_COUNT"
        fi

        SUMMARY_LINE="$(grep '"orchestrate_session_summary"' "$AMBIENT" | head -1)"

        # Check session_id propagated
        if echo "$SUMMARY_LINE" | grep -q "\"session_id\":\"$SESSION_ID\""; then
            ok "session_id matches CHUMP_ORCHESTRATE_SESSION_ID"
        else
            fail "session_id mismatch in summary (line: $SUMMARY_LINE)"
        fi

        # Check intents_routed is a number (3)
        if echo "$SUMMARY_LINE" | grep -qE '"intents_routed":[0-9]+'; then
            ok "intents_routed is a numeric field"
        else
            fail "intents_routed missing or not numeric in summary"
        fi

        # Check cost_usd is present as a number
        if echo "$SUMMARY_LINE" | grep -qE '"cost_usd":[0-9]'; then
            ok "cost_usd is a numeric field"
        else
            fail "cost_usd missing or not numeric in summary"
        fi

        # Check wall_time_s is a number
        if echo "$SUMMARY_LINE" | grep -qE '"wall_time_s":[0-9]+'; then
            ok "wall_time_s is a numeric field"
        else
            fail "wall_time_s missing or not numeric in summary"
        fi

        # Check exit_reason is present (user_quit for EOF case)
        if echo "$SUMMARY_LINE" | grep -qE '"exit_reason":"(clean|user_quit|crash|timeout)"'; then
            ok "exit_reason is a valid value"
        else
            fail "exit_reason missing or invalid in summary (line: $SUMMARY_LINE)"
        fi

        # Check intents_routed >= 1 (3 intents sent before EOF)
        ROUTED="$(echo "$SUMMARY_LINE" | grep -oE '"intents_routed":[0-9]+' | grep -oE '[0-9]+')"
        if [[ -n "$ROUTED" && "$ROUTED" -ge 1 ]]; then
            ok "intents_routed=$ROUTED (≥1, as expected)"
        else
            fail "intents_routed=$ROUTED (expected ≥1 for 3-intent session)"
        fi
    else
        fail "ambient.jsonl not created during stub session"
    fi

    # "exit" typed → exit_reason=clean
    TMP2="$(mktemp -d -t orchestrate-ci2.XXXXXX)"
    AMBIENT2="$TMP2/ambient.jsonl"
    mkdir -p "$TMP2"
    printf 'exit\n' \
      | CHUMP_ORCHESTRATE_STUB=1 \
        CHUMP_ORCHESTRATE_SESSION_ID="ci-test-1363-clean-$$" \
        CHUMP_AMBIENT_IN_PROMPT="$AMBIENT2" \
        "$CHUMP_BIN" orchestrate \
        2>&1 >/dev/null || true

    if [[ -f "$AMBIENT2" ]]; then
        EXIT_LINE="$(grep '"orchestrate_session_summary"' "$AMBIENT2" | head -1)"
        if echo "$EXIT_LINE" | grep -q '"exit_reason":"clean"'; then
            ok "exit_reason=clean when user types 'exit'"
        else
            fail "exit_reason not 'clean' when user types 'exit' (line: $EXIT_LINE)"
        fi
    else
        fail "ambient.jsonl not created for exit=clean test"
    fi
    rm -rf "$TMP2"
else
    echo "  SKIP: chump binary not found at $CHUMP_BIN — skipping integration smoke"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
