#!/usr/bin/env bash
# test-cargo-target-dir.sh — INFRA-1933
#
# Verifies that worker.sh exports CARGO_TARGET_DIR to the shared cache path
# when the env var is not already set by the caller.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Test 1: worker.sh contains the CARGO_TARGET_DIR export block ──────────────
echo "Test 1: worker.sh exports CARGO_TARGET_DIR when unset"
if grep -q 'export CARGO_TARGET_DIR' "$WORKER_SH" 2>/dev/null; then
    ok "CARGO_TARGET_DIR export found in worker.sh"
else
    fail "CARGO_TARGET_DIR export missing from worker.sh"
fi

# ── Test 2: the default path is under HOME (not a worktree-local path) ────────
echo "Test 2: default CARGO_TARGET_DIR path is outside worktrees"
if grep -A3 'CARGO_TARGET_DIR:-' "$WORKER_SH" 2>/dev/null \
        | grep -qE '(\.cargo/chump-shared-target|CHUMP_SHARED_CARGO_TARGET)'; then
    ok "CARGO_TARGET_DIR default is a shared/home path, not worktree-local"
else
    fail "CARGO_TARGET_DIR default path looks worktree-local — check worker.sh"
fi

# ── Test 3: kind=cargo_target_dir_shared registered in EVENT_REGISTRY ─────────
echo "Test 3: cargo_target_dir_shared registered in EVENT_REGISTRY.yaml"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q 'cargo_target_dir_shared' "$REGISTRY" 2>/dev/null; then
    ok "cargo_target_dir_shared in EVENT_REGISTRY.yaml"
else
    fail "cargo_target_dir_shared missing from EVENT_REGISTRY.yaml"
fi

# ── Test 4: sourcing worker.sh env block sets CARGO_TARGET_DIR ────────────────
echo "Test 4: sourcing worker.sh env block produces CARGO_TARGET_DIR"
# Extract just the env-variable-setup lines (before the function definitions)
# by sourcing up to the first function declaration in a subshell.
result=$(
    env -i HOME="$HOME" REPO_ROOT="$REPO_ROOT" PATH="$PATH" \
        bash -c '
            # Source only the variable-assignment section, not the full script.
            # We parse out lines up to the first "function " or "()" declaration.
            set -u
            REPO_ROOT="'"$REPO_ROOT"'"
            HOME="'"$HOME"'"
            # Simulate just the CARGO_TARGET_DIR block from worker.sh
            unset CARGO_TARGET_DIR 2>/dev/null || true
            CHUMP_AMBIENT_LOG=/dev/null
            eval "$(sed -n "/CARGO_TARGET_DIR/,/fi$/p" "'"$WORKER_SH"'" | head -20)"
            echo "${CARGO_TARGET_DIR:-MISSING}"
        ' 2>/dev/null || echo "EVAL_ERROR"
)
if [[ "$result" != "MISSING" && "$result" != "EVAL_ERROR" && -n "$result" ]]; then
    ok "CARGO_TARGET_DIR set to: $result"
else
    fail "CARGO_TARGET_DIR not set after worker.sh env block (got: $result)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAIL: CARGO_TARGET_DIR shared-cache wiring incomplete"
    exit 1
fi
echo "PASS: shared CARGO_TARGET_DIR correctly wired in worker.sh"
exit 0
