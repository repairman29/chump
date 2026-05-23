#!/usr/bin/env bash
# test-chump-pitch.sh — INFRA-1895 smoke.
#
# Verifies the chump-pitch wrapper invokes all 3 child scripts + the demo doc.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/chump-pitch.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

# ── Test 1: invocation produces all 4 section dividers ─────────────────────
echo "Test 1: render contains all 4 PITCH dividers"
out=$(bash "$SCRIPT" 2>&1 || true)
missing=()
for i in 1 2 3 4; do
    if ! echo "$out" | grep -q "PITCH ($i/4)"; then
        missing+=("$i")
    fi
done
if [[ ${#missing[@]} -eq 0 ]]; then
    echo "  PASS (all 4 dividers present)"
else
    echo "  FAIL: missing dividers: ${missing[*]}"
    echo "$out" | head -30
    exit 1
fi

# ── Test 2: --limit propagates to lightning-timeline ───────────────────────
echo "Test 2: --limit 20 propagates"
out=$(bash "$SCRIPT" --limit 20 2>&1 || true)
if echo "$out" | grep -q "Last-20"; then
    echo "  PASS"
else
    echo "  FAIL: --limit 20 not propagated to section header"
    exit 1
fi

# ── Test 3: --help prints usage ─────────────────────────────────────────────
echo "Test 3: --help shows usage"
out=$(bash "$SCRIPT" --help 2>&1 || true)
if echo "$out" | grep -q "chump-pitch" && echo "$out" | grep -q "paginate"; then
    echo "  PASS"
else
    echo "  FAIL: --help missing expected content"
    exit 1
fi

# ── Test 4: unknown flag exits 2 ────────────────────────────────────────────
echo "Test 4: unknown flag exits 2"
bash "$SCRIPT" --bogus-flag 2>/dev/null && rc=0 || rc=$?
if [[ "$rc" -eq 2 ]]; then
    echo "  PASS (rc=2)"
else
    echo "  FAIL: expected rc=2 on unknown flag, got rc=$rc"
    exit 1
fi

echo
echo "All 4 chump-pitch smoke tests passed."
