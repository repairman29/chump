#!/usr/bin/env bash
# test-precommit-guard-audit.sh — INFRA-508 vacuous-guard audit
#
# Verifies that guards identified as vacuous in the INFRA-508 audit
# are absent from scripts/git-hooks/pre-commit.
#
# Guards removed as vacuous (INFRA-508, 2026-05-12):
#   - Duplicate-ID guard: state.db PRIMARY KEY enforces uniqueness;
#     gap-divergence guard (INFRA-783) catches YAML/DB drift
#   - Raw-YAML removal note (3b): shrunk from 17 lines to 1-line comment

set -uo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"

echo "=== INFRA-508 pre-commit vacuous-guard audit ==="
echo

# ── 1. Duplicate-ID guard block is gone ───────────────────────────────────
echo "[1. Duplicate-ID guard removed]"
if grep -q "PYEOF_DUP" "$HOOK"; then
    fail "duplicate-ID guard (PYEOF_DUP heredoc) still present in pre-commit"
else
    ok "duplicate-ID guard removed from pre-commit"
fi

# ── 2. INFRA-GAPS-DEDUP runtime block is gone ─────────────────────────────
echo
echo "[2. INFRA-GAPS-DEDUP runtime block removed]"
if grep -qE 'INFRA-GAPS-DEDUP.*2026' "$HOOK"; then
    fail "INFRA-GAPS-DEDUP runtime comment still references active guard logic"
else
    ok "INFRA-GAPS-DEDUP runtime block removed"
fi

# ── 3. Raw-YAML removal note is condensed (not the 17-line block) ─────────
echo
echo "[3. Section 3b condensed to 1 line]"
RAWBLOCK_LINES=$(grep -c "INFRA-094.*INFRA-200\|Raw-YAML-edit guard\|CHUMP_RAW_YAML_LOCK.*no-op\|Historical bypass" "$HOOK" 2>/dev/null || echo 0)
if [ "$RAWBLOCK_LINES" -gt 2 ]; then
    fail "section 3b raw-YAML note is still expanded (found $RAWBLOCK_LINES matching lines, expected ≤ 2)"
else
    ok "section 3b condensed (≤ 2 lines — expected 1)"
fi

# ── 4. INFRA-499 audit trail still present ────────────────────────────────
echo
echo "[4. INFRA-499 audit trail preserved]"
if grep -q "INFRA-499" "$HOOK"; then
    ok "INFRA-499 removal note still present in pre-commit"
else
    fail "INFRA-499 removal note missing — audit trail lost"
fi

# ── 5. test-duplicate-id-guard.sh is gone ─────────────────────────────────
echo
echo "[5. Test for removed guard deleted]"
if [ -f "$REPO_ROOT/scripts/ci/test-duplicate-id-guard.sh" ]; then
    fail "test-duplicate-id-guard.sh still exists (tests a removed guard)"
else
    ok "test-duplicate-id-guard.sh removed"
fi

# ── 6. Line count reduced (must be ≤ 1850 after audit) ────────────────────
# Threshold: file was ~1860 before INFRA-508 audit; after removing duplicate-ID
# guard block + comment header the file was ~1680. Headroom raised over time:
#   1700 → 1750: INFRA-1060 main-worktree-config check added ~15 lines
#   1750 → 1850: CREDIBLE-054 AC enforcement guard added ~79 lines
# 1850 leaves headroom for 2-3 more small guards without breaching.
echo
echo "[6. Pre-commit line count reduced by audit]"
COUNT=$(wc -l < "$HOOK" | tr -d ' ')
if [ "$COUNT" -le 1850 ]; then
    ok "pre-commit is $COUNT lines (≤ 1850 — duplicate-ID guard deleted)"
else
    fail "pre-commit is $COUNT lines (expected ≤ 1850 after vacuous guard removal)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
