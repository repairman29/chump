#!/usr/bin/env bash
# scripts/ci/test-close-superseded-prs.sh — INFRA-994 (2026-05-14)
#
# Tests for scripts/coord/close-superseded-prs.sh:
#
#   1. Structural: script exists and is executable
#   2. Structural: script sources repo-paths.sh
#   3. Structural: emits kind=pr_auto_closed_superseded to ambient.jsonl
#   4. Structural: false-positive guard via git cherry is present
#   5. Structural: --dry-run mode prints without closing
#   6. Structural: CHUMP_SKIP_SUPERSEDED_CLOSE=1 bypass wired in main.rs
#   7. Structural: fire-and-forget spawn (non-blocking ship)
#   8. main.rs: INFRA-994 marker present
#   9. Usage: exits 1 with no arguments
#  10. Dry-run: --dry-run invoked with missing/unreachable REPO gives WARN + exits 0

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/coord/close-superseded-prs.sh"
MAIN_RS="$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== INFRA-994 close-superseded-prs test ==="
echo

# ── Test 1: script exists and is executable ───────────────────────────────────
if [[ -x "$HELPER" ]]; then
    ok "close-superseded-prs.sh exists and is executable"
else
    fail "close-superseded-prs.sh missing or not executable"
fi

# ── Test 2: sources repo-paths.sh ────────────────────────────────────────────
if grep -q "repo-paths.sh" "$HELPER"; then
    ok "script sources repo-paths.sh (path resolution)"
else
    fail "script missing repo-paths.sh source"
fi

# ── Test 3: emits pr_auto_closed_superseded event ────────────────────────────
if grep -q "pr_auto_closed_superseded" "$HELPER"; then
    ok "script emits kind=pr_auto_closed_superseded"
else
    fail "script missing pr_auto_closed_superseded emission"
fi

# ── Test 4: false-positive guard via git cherry ───────────────────────────────
if grep -q "git.*cherry" "$HELPER"; then
    ok "script uses git cherry for false-positive guard"
else
    fail "script missing git cherry false-positive guard"
fi

# ── Test 5: --dry-run mode present ───────────────────────────────────────────
if grep -q "dry.run\|DRY_RUN" "$HELPER"; then
    ok "--dry-run mode present in script"
else
    fail "--dry-run mode missing from script"
fi

# ── Test 6: CHUMP_SKIP_SUPERSEDED_CLOSE bypass in main.rs ────────────────────
if grep -q "CHUMP_SKIP_SUPERSEDED_CLOSE" "$MAIN_RS"; then
    ok "CHUMP_SKIP_SUPERSEDED_CLOSE=1 bypass present in main.rs"
else
    fail "CHUMP_SKIP_SUPERSEDED_CLOSE=1 bypass missing from main.rs"
fi

# ── Test 7: fire-and-forget spawn in main.rs ──────────────────────────────────
if grep -q "close-superseded-prs.sh" "$MAIN_RS" && grep -q "spawn.*fire-and-forget\|fire-and-forget.*spawn\|\.spawn()" "$MAIN_RS"; then
    ok "main.rs spawns close-superseded-prs.sh as fire-and-forget"
else
    fail "main.rs missing fire-and-forget spawn of close-superseded-prs.sh"
fi

# ── Test 8: INFRA-994 marker in main.rs ──────────────────────────────────────
if grep -q "INFRA-994" "$MAIN_RS"; then
    ok "INFRA-994 marker present in main.rs"
else
    fail "INFRA-994 marker missing from main.rs"
fi

# ── Test 9: usage exits 1 with no args ───────────────────────────────────────
if bash "$HELPER" 2>&1; then
    fail "should exit 1 with no args (got 0)"
else
    rc=$?
    if [[ $rc -eq 1 ]]; then
        ok "exits 1 with no arguments (usage error)"
    else
        fail "exits $rc with no arguments (expected 1)"
    fi
fi

# ── Test 10: dry-run with unreachable REPO exits 0 ───────────────────────────
# Set CHUMP_LOCK_DIR to a temp dir so ambient.jsonl writes work.
# With no GitHub remote available in CI, the script should WARN and exit 0.
DRY_RUN_OUT="$(
    CHUMP_LOCK_DIR="$TMP" \
    GIT_DIR="$REPO_ROOT/.git" \
    GIT_WORK_TREE="$REPO_ROOT" \
    bash "$HELPER" "TEST-0001" --dry-run 2>&1
)" && DRY_RC=$? || DRY_RC=$?

if [[ $DRY_RC -eq 0 ]]; then
    ok "dry-run exits 0 even with no open PRs / unreachable GitHub"
else
    fail "dry-run exited $DRY_RC (expected 0); output: $DRY_RUN_OUT"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
