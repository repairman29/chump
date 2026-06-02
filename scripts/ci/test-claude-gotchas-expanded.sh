#!/usr/bin/env bash
# test-claude-gotchas-expanded.sh — INFRA-859
# Verifies that CLAUDE_GOTCHAS.md contains the three required new sections
# with their required headers and at least one code block each.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$REPO_ROOT/docs/process/CLAUDE_GOTCHAS.md"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOC" ]] || fail "CLAUDE_GOTCHAS.md missing at $DOC"

# ── Section 1: Fleet git worktree path confusion (INFRA-779) ─────────────────
grep -q 'Fleet git worktree path confusion' "$DOC" \
    || fail "Section 'Fleet git worktree path confusion' missing"
pass "Section: Fleet git worktree path confusion present"

grep -q 'INFRA-779' "$DOC" \
    || fail "INFRA-779 reference missing"
pass "INFRA-779 referenced"

grep -q 'GIT_DIR=' "$DOC" \
    || fail "GIT_DIR recovery command missing"
grep -q 'GIT_WORK_TREE=' "$DOC" \
    || fail "GIT_WORK_TREE recovery command missing"
pass "GIT_DIR/GIT_WORK_TREE recovery commands present"

# ── Section 2: Stale lease cleanup ───────────────────────────────────────────
grep -q 'Stale lease cleanup' "$DOC" \
    || fail "Section 'Stale lease cleanup' missing"
pass "Section: Stale lease cleanup present"

grep -qE 'chump.*--release|rm.*chump-locks' "$DOC" \
    || fail "Lease release commands missing"
pass "Lease release commands present"

grep -q 'gap-preflight' "$DOC" \
    || fail "gap-preflight verification step missing from stale lease section"
pass "gap-preflight verification step present"

# ── Section 3: EVENT_REGISTRY pre-commit guard bypass ────────────────────────
grep -q 'EVENT_REGISTRY' "$DOC" \
    || fail "Section 'EVENT_REGISTRY' missing"
pass "Section: EVENT_REGISTRY present"

grep -q 'CHUMP_OBS_BUDGET_STRICT' "$DOC" \
    || fail "CHUMP_OBS_BUDGET_STRICT not documented (INFRA-2425: replaced BYPASS)"
pass "CHUMP_OBS_BUDGET_STRICT documented"

# ── Each section has at least one code block ─────────────────────────────────
code_block_count=$(grep -c '^\`\`\`' "$DOC" || echo 0)
[[ "$code_block_count" -ge 6 ]] \
    || fail "Expected >=6 code block fences (3 new sections × 2), found $code_block_count"
pass "Sufficient code blocks present ($code_block_count fences)"

printf '\nAll tests passed.\n'
