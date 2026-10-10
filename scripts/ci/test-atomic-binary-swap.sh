#!/usr/bin/env bash
# RESILIENT-493: atomic binary swap smoke test
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/scripts/ops/atomic-binary-swap.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
export CHUMP_BINARY_SWAP_AMBIENT="$TMP/ambient.jsonl"

printf '#!/bin/sh\necho old\n' > "$TMP/organ"; chmod +x "$TMP/organ"
printf '#!/bin/sh\necho new\n' > "$TMP/built"; chmod +x "$TMP/built"

bash "$SCRIPT" "$TMP/built" "$TMP/organ" || fail "swap should succeed"
[[ "$("$TMP/organ")" == new ]] || fail "target not new binary"
[[ "$("$TMP/organ.prev")" == old ]] || fail "previous binary not retained"
ls "$TMP"/organ.new.* >/dev/null 2>&1 && fail "temp file left behind"
grep -q '"kind":"binary_swap_ok"' "$CHUMP_BINARY_SWAP_AMBIENT" || fail "no ok event"
ok "swap succeeds, prev retained, no temp leftovers"

printf '#!/bin/sh\necho old\n' > "$TMP/organ"; chmod +x "$TMP/organ"
printf '#!/bin/sh\nexit 1\n' > "$TMP/fakemv"; chmod +x "$TMP/fakemv"
CHUMP_BINARY_SWAP_MV_BIN="$TMP/fakemv" bash "$SCRIPT" "$TMP/built" "$TMP/organ" 2>"$TMP/err" \
    && fail "swap should fail when rename fails"
[[ "$("$TMP/organ")" == old ]] || fail "previous binary not executable after failed swap"
grep -q 'FATAL' "$TMP/err" || fail "error not logged"
grep -q '"kind":"binary_swap_failed"' "$CHUMP_BINARY_SWAP_AMBIENT" || fail "no failed event"
ok "failed rename leaves previous binary executable and logs error"

bash "$SCRIPT" "$TMP/missing" "$TMP/organ" 2>/dev/null && fail "missing new binary should fail"
[[ "$("$TMP/organ")" == old ]] || fail "target damaged"
ok "missing new binary rejected"
echo "=== test-atomic-binary-swap.sh: ALL PASS ==="
