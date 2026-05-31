#!/usr/bin/env bash
# scripts/ci/test-pr-rescue-procedure-doc.sh — META-246
#
# Asserts the 10 anchor sections + 4 queue-states + 12 failure-surface patterns
# are present in docs/process/PR_RESCUE_PROCEDURE.md so the doctrine survives
# future doc edits without silently regressing.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOC="$REPO_ROOT/docs/process/PR_RESCUE_PROCEDURE.md"
FAILED=0

assert_contains() {
  local needle="$1"
  if ! grep -qF "$needle" "$DOC" 2>/dev/null; then
    echo "[pr-rescue-doc] FAIL: $DOC missing '$needle'" >&2
    FAILED=1
  fi
}

# File must exist
if [[ ! -f "$DOC" ]]; then
  echo "[pr-rescue-doc] FAIL: $DOC does not exist" >&2
  exit 1
fi

# 10 anchor sections
assert_contains "## TL;DR"
assert_contains "## 1. When to use this"
assert_contains "## 2. Triage protocol"
assert_contains "## 3. Systemic rot"
assert_contains "## 4. Queue-state taxonomy"
assert_contains "## 5. Failure-surface taxonomy"
assert_contains "## 6. Cascade impact tables"
assert_contains "## 7. Merge-order pyramid"
assert_contains "## 8. Admin-merge safety gates"
assert_contains "## 9. Daemon coordination matrix"
assert_contains "## 10. Collision-prone file watch list"
assert_contains "## 11. Decision flowchart"
assert_contains "## 12. Anti-patterns"

# 4 queue-states required
assert_contains "BLOCKED"
assert_contains "BEHIND"
assert_contains "DIRTY"
assert_contains "UNKNOWN"

# 6 daemon-classification sub-states (META-183 + META-185 framework)
assert_contains "MERGEABLE"
assert_contains "ARMED"
assert_contains "BLOCKED_GREEN"
assert_contains "BLOCKED_REAL_FAIL"

# 12 failure-surface patterns by name (or by their detect signal)
assert_contains "Allowlist drift"
assert_contains "Install manifest gate"
assert_contains "EMIT-NO-REG sweep"
assert_contains "Register-without-emit orphans"
assert_contains "test-pre-push-test-gate"
assert_contains "sccache R2 cred broken"
assert_contains "Cranelift component unavailable"
assert_contains "chump-integrator merge_branch"
assert_contains "Pr-shepherd-daemon self-allowlist"
assert_contains "Auto-merge-rearm daemon allowlist"
assert_contains "Flaky test"
assert_contains "Ghost PRs"

# Cited substrate gaps
assert_contains "INFRA-2314"
assert_contains "INFRA-2315"
assert_contains "INFRA-2308"
assert_contains "INFRA-2297"
assert_contains "RESILIENT-041"
assert_contains "META-186"
assert_contains "META-207"
assert_contains "META-225"

# Authority / discipline references
assert_contains "operator-decision-of-record 2026-05-31"
assert_contains "Off-Rails-Bypass"
assert_contains "fix-class allowlist"
assert_contains "T1-T4"

if [[ "$FAILED" -ne 0 ]]; then
  echo "[pr-rescue-doc] FAIL — doctrine drift detected; one or more required anchors missing" >&2
  exit 1
fi

echo "[pr-rescue-doc] PASS — all 10 sections + 4 queue-states + 6 daemon-states + 12 surfaces + substrate refs present"
