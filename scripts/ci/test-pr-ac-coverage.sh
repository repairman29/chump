#!/usr/bin/env bash
# INFRA-1541: exec wrapper for `chump pr ac-coverage <PR#>` (logic in src/pr_ac_coverage.rs).
# When invoked with zero arguments (e.g. scripts/ci census), smoke-tests the subcommand CLI contract.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$ROOT/target}/debug/chump}"
if [[ ! -x "$BIN" ]] && [[ -x "$ROOT/target/release/chump" ]]; then
    BIN="$ROOT/target/release/chump"
elif [[ ! -x "$BIN" ]] && command -v chump >/dev/null 2>&1; then
    BIN="$(command -v chump)"
fi
if [[ $# -eq 0 ]]; then
    rc=0
    out="$("$BIN" pr ac-coverage 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]] && grep -q "Usage: chump pr ac-coverage" <<<"$out"; then
        echo "PASS: chump pr ac-coverage usage contract verified"
        exit 0
    fi
    echo "FAIL: unexpected zero-arg behavior (rc=$rc): $out" >&2
    exit 1
fi
exec "$BIN" pr ac-coverage "$@"
