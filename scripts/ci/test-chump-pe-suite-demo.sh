#!/usr/bin/env bash
# test-chump-pe-suite-demo.sh — smoke test for the 5-min P&E suite demo
#
# INFRA-2282: ensure the demo runs end-to-end on macOS bash 3.2 (Apple's
# default — no `declare -A` support). Earlier `declare -A` usage in
# Beats 4-5 broke the demo for every default-macOS evaluator.
#
# Asserts:
#   1. scripts/demo/chump-pe-suite-demo.sh exits 0 when invoked under /bin/bash
#   2. All 5 beat headers appear in output
#   3. "Demo complete" terminator line prints
#   4. The `consensus_decision_emitted` ambient line lands in the fixture stream

set -euo pipefail

# Resolve relative to THIS test script so we test the demo in the current
# worktree, not whichever working tree git rev-parse happens to land in.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_SCRIPT="$SCRIPT_DIR/../demo/chump-pe-suite-demo.sh"

if [[ ! -x "$DEMO_SCRIPT" ]]; then
    echo "[test-pe-suite-demo] FAIL: demo script not executable at $DEMO_SCRIPT" >&2
    exit 1
fi

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

# Use the system /bin/bash explicitly to catch bash-3.2 regressions even
# when the dev's PATH points at homebrew bash 5.
if ! /bin/bash "$DEMO_SCRIPT" --fast > "$OUT" 2>&1; then
    echo "[test-pe-suite-demo] FAIL: demo exited non-zero on /bin/bash" >&2
    tail -20 "$OUT" >&2
    exit 1
fi

FAILED=0
for beat in "BEAT 1 — Install" "BEAT 2 — Status" "BEAT 3 — Operator asks" \
            "BEAT 4 — Curators reply" "BEAT 5 — Resolve"; do
    if ! grep -qF "$beat" "$OUT"; then
        echo "[test-pe-suite-demo] FAIL: beat header missing: $beat" >&2
        FAILED=1
    fi
done

if ! grep -qF "Demo complete." "$OUT"; then
    echo "[test-pe-suite-demo] FAIL: 'Demo complete.' terminator missing" >&2
    FAILED=1
fi

# Verify the fixture ambient stream got the consensus_decision_emitted event
FIXTURE_DIR="${TMPDIR:-/tmp}/synthetic-api"
FIXTURE_AMBIENT="$FIXTURE_DIR/.chump/ambient.jsonl"
if [[ -f "$FIXTURE_AMBIENT" ]]; then
    if ! grep -q '"kind":"consensus_decision_emitted"' "$FIXTURE_AMBIENT"; then
        echo "[test-pe-suite-demo] FAIL: consensus_decision_emitted missing from fixture ambient" >&2
        FAILED=1
    fi
else
    echo "[test-pe-suite-demo] FAIL: fixture ambient file not created at $FIXTURE_AMBIENT" >&2
    FAILED=1
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "" >&2
    echo "=== full demo output ===" >&2
    cat "$OUT" >&2
    exit 1
fi

echo "[test-pe-suite-demo] PASS — demo ran end-to-end on /bin/bash, all 5 beats + terminator present"
exit 0
