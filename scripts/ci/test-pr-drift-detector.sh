#!/usr/bin/env bash
# test-pr-drift-detector.sh — regression cases for INFRA-104
#
# All cases run in offline mode (`--title`/`--files`) so the test does NOT
# need gh CLI auth or network. Backtest cases that require real PR data are
# documented in the script header comment but only run when CI sets
# CHUMP_DRIFT_LIVE_BACKTEST=1.
#
# Each case asserts a specific exit code from check-pr-drift.sh under
# CHUMP_DRIFT_FAIL=1 (so drift → exit 1).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHECK="$REPO_ROOT/scripts/ci/check-pr-drift.sh"

if [[ ! -x "$CHECK" ]]; then
    echo "FATAL: $CHECK not executable" >&2
    exit 2
fi

PASS=0
FAIL=0
FAILED_CASES=()

run_case() {
    local name="$1"
    local expected="$2"  # 0 = no drift, 1 = drift detected
    shift 2
    local actual=0
    set +e
    CHUMP_DRIFT_FAIL=1 "$CHECK" "$@" >/tmp/drift-test.out 2>&1
    actual=$?
    set -e
    if [[ "$actual" == "$expected" ]]; then
        echo "  ok    $name (exit=$actual)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name (expected=$expected actual=$actual)"
        echo "  ---- output ----"
        sed 's/^/    /' /tmp/drift-test.out
        echo "  ----------------"
        FAIL=$((FAIL + 1))
        FAILED_CASES+=("$name")
    fi
}

echo "=== Case 1: clean PR (gap-ID + matching source files) → no drift"
run_case "clean: INFRA-XXX with src/ change" 0 \
    --title "INFRA-104: PR title-vs-implementation drift detector" \
    --files "scripts/ci/check-pr-drift.sh,scripts/ci/test-pr-drift-detector.sh,.github/workflows/ci.yml"

echo "=== Case 2: filing-only — title mentions gap, only YAML changed → DRIFT"
run_case "filing-only: bare ID + only docs/gaps/<ID>.yaml" 1 \
    --title "INFRA-999: implement reaper redesign" \
    --files "docs/gaps/INFRA-999.yaml"

echo "=== Case 3: ledger-only PR by title prefix → SKIP (no drift)"
run_case "skip: chore(gaps) prefix" 0 \
    --title "chore(gaps): file INFRA-246 + META-014" \
    --files "docs/gaps/INFRA-246.yaml,docs/gaps/META-014.yaml"

echo "=== Case 4: no gap-ID in title → SKIP (no drift)"
run_case "skip: no gap-ID" 0 \
    --title "fix: typo in README" \
    --files "README.md"

echo "=== Case 5: null-impact — only registry/state files → DRIFT"
run_case "null-impact: only state.sql changed" 1 \
    --title "INFRA-500: refactor inference pipeline" \
    --files ".chump/state.sql,.chump-locks/ambient.jsonl"

echo "=== Case 6: multi-gap title with one-PR-implements-one — first ok, others miss"
# This is the canonical PR #565 backtest shape: title cites four IDs but
# the diff only includes one.
run_case "multi-gap title, src change → no drift (any signal counts)" 0 \
    --title "INFRA-087/088/089/090: mandate chump gap canonical path" \
    --files "src/gap_store.rs,scripts/coord/gap-claim.sh"

echo "=== Case 7: doc-only change for a gap whose hints are doc-shaped → no drift"
run_case "doc-only: matches doc bucket" 0 \
    --title "DOC-010: nine-proxies reframe" \
    --files "docs/research/PROXIES.md,docs/process/RESEARCH_INTEGRITY.md"

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "All $PASS test(s) passed."
    exit 0
else
    echo "$FAIL of $((PASS + FAIL)) test(s) failed:"
    for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
    exit 1
fi
