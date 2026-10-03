#!/usr/bin/env bash
# test-claude-md-budget.sh — ZERO-WASTE-125 AC4
#
# Hard line-count budget on the two root rulebook files. The rulebook
# outgrows what an agent can hold in context (measured 2026-09-29: CLAUDE.md
# 700 lines + AGENTS.md 1129 lines). A hard cap forces one-in-one-out: once
# a file is at budget, landing a new rule requires removing an equivalent
# number of lines elsewhere in the same file.
#
# Usage: scripts/ci/test-claude-md-budget.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CLAUDE_MD_BUDGET=150
AGENTS_MD_BUDGET=300

fail=0

check_budget() {
    local file="$1"
    local budget="$2"
    if [[ ! -f "$file" ]]; then
        echo "FAIL: $file not found"
        fail=1
        return
    fi
    local lines
    lines=$(wc -l < "$file" | tr -d ' ')
    if (( lines > budget )); then
        echo "FAIL: $file is $lines lines, budget is $budget."
        echo "  Move detail to an on-demand doc under docs/process/ rather than growing this file."
        echo "  See docs/process/RULE_REGISTRY.json / 'chump rules audit' for prune candidates first."
        fail=1
    else
        echo "OK: $file is $lines/$budget lines"
    fi
}

check_budget "CLAUDE.md" "$CLAUDE_MD_BUDGET"
check_budget "AGENTS.md" "$AGENTS_MD_BUDGET"

exit $fail
