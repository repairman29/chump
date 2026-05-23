#!/usr/bin/env bash
# scripts/ci/test-pr-auto-rebase-blocked.sh — INFRA-1838
#
# Verify pr-auto-rebase.sh handles BLOCKED+armed PRs (added INFRA-1838) in
# addition to the original DIRTY|BEHIND handling.
#
# Regression scenario (2026-05-23): 13 PRs sat BLOCKED+armed for hours after
# main moved because the original filter only caught DIRTY|BEHIND. CI ran
# against an older main, marked the PR as BLOCKED, and nothing ever
# triggered a re-rebase. Operator had to manually run gh pr update-branch
# on all 13.
#
# Tests are STRUCTURAL (grep the script for the right filter shape) rather
# than functional (which would require mocking gh + a real worktree). The
# structural assertions are sufficient to catch the regression of removing
# BLOCKED from the filter or breaking the bypass env var.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$SCRIPT_DIR/scripts/coord/pr-auto-rebase.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$TARGET" ]] || fail "$TARGET missing"

# ── 1. BLOCKED appears in the default state filter ─────────────────────────
if grep -qE 'mergeStateStatus == "BLOCKED"' "$TARGET"; then
    ok "default filter includes BLOCKED (INFRA-1838)"
else
    fail "default filter does NOT include BLOCKED — INFRA-1838 regression"
fi

# ── 2. DIRTY + BEHIND still present (no regression of original behavior) ───
grep -qE 'mergeStateStatus == "DIRTY"'  "$TARGET" || fail "DIRTY filter removed (regression)"
grep -qE 'mergeStateStatus == "BEHIND"' "$TARGET" || fail "BEHIND filter removed (regression)"
ok "original DIRTY + BEHIND filters preserved"

# ── 3. Bypass env var implemented ──────────────────────────────────────────
if grep -q 'CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED' "$TARGET"; then
    ok "bypass env CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED present"
else
    fail "bypass env CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED not implemented"
fi

# ── 4. Bypass actually narrows the filter (DIRTY|BEHIND only) ──────────────
# Look for the bypass branch reverting the filter to the pre-1838 shape.
if grep -A 2 'CHUMP_PR_AUTO_REBASE_SKIP_BLOCKED' "$TARGET" | grep -qE 'mergeStateStatus == "DIRTY" or .mergeStateStatus == "BEHIND"'; then
    ok "bypass path restores pre-1838 filter shape"
else
    fail "bypass branch does not restore DIRTY|BEHIND filter"
fi

# ── 5. Cooldown / MAX_PER_HOUR still enforced (no runaway rebasing) ────────
grep -qE 'MAX_PER_HOUR' "$TARGET" || fail "MAX_PER_HOUR cap removed — runaway risk"
grep -qE 'cooldown_count'  "$TARGET" || fail "cooldown_count helper removed"
ok "cooldown cap + per-PR cooldown_count still enforced"

# ── 6. INFRA-1838 attribution comment present ──────────────────────────────
if grep -q 'INFRA-1838' "$TARGET"; then
    ok "INFRA-1838 attribution comment present"
else
    fail "no INFRA-1838 attribution comment — set when/why someone reads the script later"
fi

# ── 7. Script still passes a smoke parse ──────────────────────────────────
bash -n "$TARGET" || fail "script has syntax error"
ok "script parses cleanly via bash -n"

echo ""
echo "ALL INFRA-1838 smoke assertions passed."
