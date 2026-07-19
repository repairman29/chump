#!/usr/bin/env bash
# test-cartographer-smoke.sh — INFRA-1782
#
# Smoke test for `chump cartograph <path>` (Phase 2 Cartographer):
#  - scans a tiny fixture repo
#  - writes <fixture>/docs/ARCHITECTURE.md with expected sections
#  - emits cartographer_started + cartographer_completed to ambient.jsonl
#  - a bad path exits non-zero and emits cartographer_failed

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
TARGET_DIR="$(cd "$REPO_ROOT" && cargo metadata --no-deps --format-version 1 2>/dev/null | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null || echo "$REPO_ROOT/target")"
BIN="$TARGET_DIR/debug/chump"

if [ ! -x "$BIN" ]; then
    echo "building chump (debug)..."
    (cd "$REPO_ROOT" && cargo build --bin chump --quiet)
fi

FIXTURE="$(mktemp -d)"
mkdir -p "$FIXTURE/src"
echo 'fn main() {}' > "$FIXTURE/src/main.rs"
trap 'rm -rf "$FIXTURE"' EXIT

echo "=== INFRA-1782 cartographer smoke test ==="
echo

# cartographer emits to repo_path::repo_root(), which resolves CHUMP_REPO /
# CHUMP_HOME first — the main checkout in a linked-worktree fleet setup, not
# necessarily $REPO_ROOT.
AMBIENT_REPO="${CHUMP_REPO:-${CHUMP_HOME:-$REPO_ROOT}}"
mkdir -p "$AMBIENT_REPO/.chump-locks"
touch "$AMBIENT_REPO/.chump-locks/ambient.jsonl"

if "$BIN" cartograph "$FIXTURE" >/tmp/cartograph-out-$$.txt 2>&1; then
    ok "chump cartograph exits 0 on valid path"
else
    fail "chump cartograph exited non-zero on valid path"
fi

if [ -f "$FIXTURE/docs/ARCHITECTURE.md" ]; then
    ok "ARCHITECTURE.md written"
else
    fail "ARCHITECTURE.md missing"
fi

if grep -q "^## Entry points" "$FIXTURE/docs/ARCHITECTURE.md" 2>/dev/null && \
   grep -q "main.rs" "$FIXTURE/docs/ARCHITECTURE.md" 2>/dev/null; then
    ok "ARCHITECTURE.md lists detected entry point"
else
    fail "ARCHITECTURE.md missing expected entry-point section/content"
fi

if tail -n 20 "$AMBIENT_REPO/.chump-locks/ambient.jsonl" 2>/dev/null | grep -q '"kind":"cartographer_started"'; then
    ok "cartographer_started emitted"
else
    fail "cartographer_started not found in ambient.jsonl"
fi

if tail -n 20 "$AMBIENT_REPO/.chump-locks/ambient.jsonl" 2>/dev/null | grep -q '"kind":"cartographer_completed"'; then
    ok "cartographer_completed emitted"
else
    fail "cartographer_completed not found in ambient.jsonl"
fi

if "$BIN" cartograph /nonexistent/path/does-not-exist-xyz >/tmp/cartograph-bad-$$.txt 2>&1; then
    fail "chump cartograph should exit non-zero on a missing path"
else
    ok "chump cartograph exits non-zero on a missing path"
fi

if tail -n 20 "$AMBIENT_REPO/.chump-locks/ambient.jsonl" 2>/dev/null | grep -q '"kind":"cartographer_failed"'; then
    ok "cartographer_failed emitted for bad path"
else
    fail "cartographer_failed not found in ambient.jsonl"
fi

rm -f /tmp/cartograph-out-$$.txt /tmp/cartograph-bad-$$.txt

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
