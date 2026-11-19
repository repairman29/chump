#!/usr/bin/env bash
# scripts/ci/test-check-dead-env-vars-broken-pipe.sh — INFRA-1801
#
# Regression test for the printf | head -10 SIGPIPE race in
# scripts/audit/auditor-checks/check-dead-env-vars.sh. Prior to INFRA-1801,
# when the undoc array held >10 entries, head closed the pipe after reading
# 10 lines but printf was still writing, triggering "printf: write error:
# Broken pipe" on stderr and (with set -e + pipefail) failing the fast-checks
# job.
#
# Fix: slice the array to 10 elements BEFORE printf so head doesn't need to
# close the pipe early.
#
# This test exercises the same pipeline shape in isolation with a
# 50-element synthetic array; pre-fix it produced a broken-pipe error on
# stderr; post-fix it's silent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/audit/auditor-checks/check-dead-env-vars.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static check: confirm INFRA-1801 fix shape is in place ─────────────
[[ -f "$SCRIPT" ]] || fail "$SCRIPT missing"

if grep -qE 'undoc\[@\]:0:10' "$SCRIPT"; then
    ok "script uses array-slice form (undoc[@]:0:10)"
else
    fail "script does not use array-slice form — broken-pipe race likely present"
fi

if grep -q 'head -10' "$SCRIPT" 2>/dev/null; then
    if grep -qE 'undoc\[@\]" \| head -10' "$SCRIPT"; then
        fail "script still has the printf | head -10 pipeline — SIGPIPE race lives on"
    fi
fi
ok "no printf | head -10 pipeline form present"

# ── 2. Runtime: synthesize a 50-element array and run the pipeline ─────────
# Mirrors the exact pipeline shape in the fix, in isolation, with set -e
# and pipefail enabled. Pre-fix this would emit "printf: write error: Broken
# pipe" to stderr and exit non-zero.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bash -c '
set -euo pipefail

# Build a 50-element synthetic array of CHUMP_FAKE_* var names
undoc=()
for i in $(seq 1 50); do
    undoc+=("CHUMP_FAKE_VAR_$i")
done

# Exact pipeline shape from the post-fix script
samples_json="$(printf "%s\n" "${undoc[@]:0:10}" | python3 -c "
import json, sys
print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))
")"

# Verify output has exactly 10 entries
count=$(printf "%s" "$samples_json" | python3 -c "import json, sys; print(len(json.load(sys.stdin)))")
if [[ "$count" != "10" ]]; then
    echo "FAIL: expected 10 samples, got $count" >&2
    exit 1
fi
' 2>"$TMP/stderr.log"
rc=$?

if [[ $rc -ne 0 ]]; then
    echo "stderr was:"
    cat "$TMP/stderr.log"
    fail "pipeline failed unexpectedly (rc=$rc)"
fi

if grep -q "Broken pipe" "$TMP/stderr.log"; then
    fail "broken-pipe error still appears in stderr — fix is incomplete"
fi
ok "synthetic 50-element array: pipeline exits 0 with no broken-pipe in stderr"

echo ""
echo "ALL INFRA-1801 broken-pipe regression tests passed."
