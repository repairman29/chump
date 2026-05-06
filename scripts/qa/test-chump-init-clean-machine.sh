#!/usr/bin/env bash
# scripts/qa/test-chump-init-clean-machine.sh
#
# AC (g): simulate a clean-machine first run of `chump init` and assert all
# outputs are created correctly.  Runs entirely inside a tempdir; does NOT
# require brew, Ollama, or a live network.
#
# Usage: bash scripts/qa/test-chump-init-clean-machine.sh [--binary PATH]
#
# Exits 0 on pass, 1 on any assertion failure.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-chump}"
PASS=0
FAIL=0
ERRORS=()

# ── helpers ──────────────────────────────────────────────────────────────────

ok() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); ERRORS+=("$1"); }

assert_file_exists() {
    local path="$1" label="${2:-$1}"
    if [[ -f "$path" ]]; then ok "$label exists"; else fail "$label missing"; fi
}

assert_file_contains() {
    local path="$1" needle="$2" label="${3:-contains '$2'}"
    if grep -qF "$needle" "$path" 2>/dev/null; then ok "$label"; else fail "$label (not found in $path)"; fi
}

assert_output_contains() {
    local output="$1" needle="$2" label="${3:-output contains '$2'}"
    if echo "$output" | grep -qF "$needle"; then ok "$label"; else fail "$label"; fi
}

assert_sqlite_table() {
    local db="$1" table="$2"
    if sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null | grep -q "^$table$"; then
        ok "state.db table '$table'"
    else
        fail "state.db table '$table' missing"
    fi
}

# ── setup tempdir ─────────────────────────────────────────────────────────────

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_HOME" "$FAKE_REPO" "$FAKE_REPO/.git"

echo "Test root: $TMP"
echo

# ── run chump init ────────────────────────────────────────────────────────────
# Export CHUMP_HOME so ~/.chump resolves to $FAKE_HOME/.chump
# Export ANTHROPIC_API_KEY to skip interactive API-key prompt
# Use --no-browser --no-interactive so the wizard is fully non-interactive
# Set HOME so the binary sees a clean home dir (no real ~/.chump leaking)

export HOME="$FAKE_HOME"
export CHUMP_HOME="$FAKE_HOME/.chump"
export ANTHROPIC_API_KEY="sk-ant-test-key-for-qa"
export FLEET_MODEL="sonnet"

# Run from the fake repo root so .env is written there.
# If the binary isn't in PATH, skip execution and only run unit-level checks.
if command -v "$CHUMP_BIN" &>/dev/null; then
    OUTPUT="$(cd "$FAKE_REPO" && \
        CHUMP_HOME="$FAKE_HOME/.chump" \
        HOME="$FAKE_HOME" \
        ANTHROPIC_API_KEY="sk-ant-test-key-for-qa" \
        FLEET_MODEL="sonnet" \
        "$CHUMP_BIN" init --no-browser --no-interactive 2>&1 || true)"
    echo "$OUTPUT"
    echo

    # (f) next-step hint in output
    assert_output_contains "$OUTPUT" "chump init complete" "(f) next-step hint printed"
    assert_output_contains "$OUTPUT" "chump gen" "(f) chump gen hint present"
    assert_output_contains "$OUTPUT" "chump fleet start" "(f) chump fleet start hint present"

    # (b) config.toml written
    assert_file_exists "$FAKE_HOME/.chump/config.toml" "(b) config.toml"
    assert_file_contains "$FAKE_HOME/.chump/config.toml" "fleet_model" "(b) fleet_model in config.toml"
    assert_file_contains "$FAKE_HOME/.chump/config.toml" "sk-ant-test-key-for-qa" "(b) api key in config.toml"

    # (c) FLEET_MODEL in config
    assert_file_contains "$FAKE_HOME/.chump/config.toml" 'fleet_model = "sonnet"' "(c) FLEET_MODEL=sonnet"

    # (e) state.db scaffold
    assert_file_exists "$FAKE_HOME/.chump/state.db" "(e) state.db"
    if command -v sqlite3 &>/dev/null; then
        assert_sqlite_table "$FAKE_HOME/.chump/state.db" "gaps"
        assert_sqlite_table "$FAKE_HOME/.chump/state.db" "gap_log"
    else
        echo "  SKIP  sqlite3 not in PATH — skipping table assertions"
    fi

else
    echo "  SKIP  '$CHUMP_BIN' not found in PATH — running file-level checks only"
    echo "        Set CHUMP_BIN=/path/to/chump to run integration checks."
fi

# ── static: unit-testable helpers via cargo test ──────────────────────────────
# Even without the binary, we validate the Rust unit tests pass.
if command -v cargo &>/dev/null; then
    echo
    echo "Running unit tests for chump_init..."
    if cargo test --quiet -p chump chump_init 2>&1 | tail -5; then
        ok "cargo test chump_init unit tests"
    else
        fail "cargo test chump_init failed"
    fi
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "Failures:"
    for e in "${ERRORS[@]}"; do echo "  - $e"; done
fi

[[ $FAIL -eq 0 ]]
