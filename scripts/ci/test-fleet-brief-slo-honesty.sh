#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# test-fleet-brief-slo-honesty.sh — CREDIBLE-120
#
# `chump fleet brief` must not report "fleet looks healthy" while
# `chump health --slo-check` reports a breach. CHUMP_FAKE_SLO_BREACH=1
# injects a synthetic breached SLO.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$(dirname "$0")/lib/discover-chump-bin.sh"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: chump binary not found at $CHUMP_BIN"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/.chump-locks" "$TMP/repo/.chump"
git -C "$TMP/repo" init -q

echo "Test 1: synthetic SLO breach => brief says SLO BREACH, not healthy"
OUT="$(CHUMP_FAKE_SLO_BREACH=1 CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" fleet brief 2>/dev/null)"
if echo "$OUT" | grep -q "SLO BREACH" && ! echo "$OUT" | grep -q "fleet looks healthy"; then
    echo "  PASS"
else
    echo "  FAIL: got:"
    echo "$OUT"
    exit 1
fi

echo "Test 2: health --slo-check exits non-zero under the same fixture"
if CHUMP_FAKE_SLO_BREACH=1 CHUMP_REPO="$TMP/repo" "$CHUMP_BIN" health --slo-check >/dev/null 2>&1; then
    echo "  FAIL: expected non-zero exit"
    exit 1
fi
echo "  PASS"

echo "All tests passed."
