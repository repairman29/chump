#!/usr/bin/env bash
# test-cargo-target-reaper-honesty.sh — RESILIENT-130
# A failing reaper run must leave a kind=cargo_target_reaper_run rc!=0 event in
# ambient; a clean run must emit rc=0.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$(cd "$SCRIPT_DIR/../.." && pwd)/scripts/ops/cargo-target-reaper.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "  FAIL $*" >&2; exit 1; }

echo "--- failing run (unknown flag) emits rc=1 ---"
A="$T/fail.jsonl"
CHUMP_AMBIENT_LOG="$A" bash "$REAPER" --bogus-flag >/dev/null 2>&1 && fail "expected non-zero exit"
grep '"kind":"cargo_target_reaper_run"' "$A" | grep -q '"rc":1' || fail "no rc=1 event"
grep '"kind":"cargo_target_reaper_run"' "$A" | grep -q '"error_msg":"unknown flag' || fail "no error_msg"
echo "  PASS"

echo "--- clean run (--help) emits rc=0 ---"
A="$T/ok.jsonl"
CHUMP_AMBIENT_LOG="$A" bash "$REAPER" --help >/dev/null 2>&1 || fail "help exited non-zero"
grep '"kind":"cargo_target_reaper_run"' "$A" | grep -q '"rc":0' || fail "no rc=0 event"
echo "  PASS"
echo "=== all passed ==="
