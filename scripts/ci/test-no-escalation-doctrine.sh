#!/usr/bin/env bash
# scripts/ci/test-no-escalation-doctrine.sh — META-207
#
# Asserts the doctrine anchor headers + 4 legitimate trigger codes (T1-T4)
# are present in AGENTS.md, CLAUDE.md, and SUBAGENT_DISPATCH.md so the rule
# survives future doc edits without silently regressing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FAILED=0

assert_contains() {
  local file="$1"; shift
  local needle="$1"; shift
  if ! grep -qF "$needle" "$REPO_ROOT/$file"; then
    echo "[no-escalation-doctrine] FAIL: $file missing '$needle'" >&2
    FAILED=1
  fi
}

# AGENTS.md — canonical
assert_contains "AGENTS.md" "No-operator-escalation discipline"
assert_contains "AGENTS.md" "operator-decision-of-record 2026-05-30"
assert_contains "AGENTS.md" "T1"
assert_contains "AGENTS.md" "T2"
assert_contains "AGENTS.md" "T3"
assert_contains "AGENTS.md" "T4"
assert_contains "AGENTS.md" "operator_escalation_unjustified"

# CLAUDE.md — overlay
assert_contains "CLAUDE.md" "No-escalation overlay"
assert_contains "CLAUDE.md" "T1-T4"

# SUBAGENT_DISPATCH.md — sub-agent inheritance
assert_contains "docs/process/SUBAGENT_DISPATCH.md" "No-operator-escalation"
assert_contains "docs/process/SUBAGENT_DISPATCH.md" "T1-T4"

if [[ "$FAILED" -ne 0 ]]; then
  echo "[no-escalation-doctrine] FAIL — doctrine drift detected; one or more required anchors missing" >&2
  exit 1
fi

echo "[no-escalation-doctrine] PASS — doctrine anchors present in all 3 docs"
