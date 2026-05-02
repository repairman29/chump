#!/usr/bin/env bash
# Regression for INFRA-020: invented gap IDs must fail preflight unless bypass env is set.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

BOGUS="ZZZ-INFRA-020-UNREGISTERED-BOGUS-ID"

set +e
out="$(scripts/coord/gap-preflight.sh "$BOGUS" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 1 ]]; then
    echo "expected exit 1 for unregistered gap, got $rc" >&2
    echo "$out" >&2
    exit 1
fi
# INFRA-188: gap-preflight.sh now emits "not found in gap registry (docs/gaps/ or docs/gaps.yaml)"
# to cover both per-file and monolithic layouts. Match either form.
if ! echo "$out" | grep -qE "not found in (docs/gaps\.yaml|gap registry)"; then
    echo "expected 'not found in docs/gaps.yaml' or 'not found in gap registry' in output" >&2
    echo "$out" >&2
    exit 1
fi

set +e
out_ok="$(CHUMP_ALLOW_UNREGISTERED_GAP=1 scripts/coord/gap-preflight.sh "$BOGUS" 2>&1)"
rc_ok=$?
set -e
if [[ "$rc_ok" -ne 0 ]]; then
    echo "expected exit 0 with CHUMP_ALLOW_UNREGISTERED_GAP=1, got $rc_ok" >&2
    echo "$out_ok" >&2
    exit 1
fi
if ! echo "$out_ok" | grep -q "CHUMP_ALLOW_UNREGISTERED_GAP=1"; then
    echo "expected bypass mention in output" >&2
    echo "$out_ok" >&2
    exit 1
fi

echo "ok: gap-preflight rejects unregistered ID; bypass env works"
