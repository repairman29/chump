#!/usr/bin/env bash
# INFRA-1667 — regression guard: opus-curator must invoke chump waste-tally
# with --json so jq receives parseable input. Without --json, waste-tally
# prints a formatted text report, jq exits 5 (parse error), pipefail
# propagates, and set -euo pipefail kills every 10-min curator tick.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/opus-curator.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not found"
    exit 1
fi

# 1. The waste-tally call line must include --json.
if ! grep -qE 'chump waste-tally[^|]*--json' "$SCRIPT"; then
    echo "FAIL: opus-curator.sh waste-tally invocation missing --json flag"
    echo "      This causes jq exit 5 → set -e kills the script (INFRA-1667)"
    grep -n 'chump waste-tally' "$SCRIPT" || true
    exit 1
fi

# 2. Regression guard: no waste-tally|jq pipeline without --json should exist.
if grep -nE 'chump waste-tally[^|]*\|[[:space:]]*jq' "$SCRIPT" | grep -v -- '--json' >/dev/null 2>&1; then
    echo "FAIL: found waste-tally | jq pipeline without --json (INFRA-1667 regression)"
    grep -nE 'chump waste-tally[^|]*\|[[:space:]]*jq' "$SCRIPT" | grep -v -- '--json'
    exit 1
fi

# 3. Empirical: chump waste-tally --json output must be valid JSON parseable by jq.
#    Skip this check if chump binary unavailable (CI minimal envs).
if command -v chump >/dev/null 2>&1; then
    if ! chump waste-tally --since 2h --json 2>/dev/null | jq . >/dev/null 2>&1; then
        echo "FAIL: chump waste-tally --since 2h --json does not produce jq-parseable output"
        echo "      The opus-curator fix assumes valid JSON; if this changes, update the script."
        exit 1
    fi
fi

echo "OK INFRA-1667: opus-curator waste-tally call uses --json (jq parse safe)"
