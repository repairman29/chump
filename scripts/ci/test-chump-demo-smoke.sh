#!/usr/bin/env bash
# scripts/ci/test-chump-demo-smoke.sh — INFRA-2391
#
# Smoke test for `chump demo` (crates/chump-demo wired as a subcommand).
# Asserts:
#   1. `chump demo --help` exits 0
#   2. `chump demo --dry-run` exits 0 end-to-end and writes a report

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Locate chump binary ───────────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP_BIN="$REPO_ROOT/target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP_BIN="$(command -v chump)"
    else
        echo "SKIP: chump binary not found (set CHUMP_BIN or run cargo build first)" >&2
        exit 0
    fi
fi

echo "── Phase 0: binary present ──"
[[ -x "$CHUMP_BIN" ]] && ok "chump binary executable at $CHUMP_BIN" || { fail "chump binary not executable"; exit 1; }

echo "── Phase 1: chump demo --help ──"
if "$CHUMP_BIN" demo --help &>/dev/null; then
    ok "chump demo --help exits 0"
else
    fail "chump demo --help failed"
fi

echo "── Phase 2: chump demo --dry-run end-to-end ──"
WORK_DIR=$(mktemp -d)
REPORT_PATH="$WORK_DIR/report.json"
AMBIENT_PATH="$WORK_DIR/ambient.jsonl"
: > "$AMBIENT_PATH"

if "$CHUMP_BIN" demo --dry-run --seed 1 --duration 1s \
    --report-path "$REPORT_PATH" --ambient-log "$AMBIENT_PATH" &>/dev/null; then
    ok "chump demo --dry-run exits 0"
else
    fail "chump demo --dry-run exited non-zero"
fi

if [[ -f "$REPORT_PATH" ]]; then
    ok "report written to $REPORT_PATH"
    if grep -q '"schema_version"' "$REPORT_PATH"; then
        ok "report has schema_version field"
    else
        fail "report missing schema_version field"
    fi
else
    fail "report not written"
fi

rm -rf "$WORK_DIR"

echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
