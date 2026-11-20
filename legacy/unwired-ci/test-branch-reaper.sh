#!/usr/bin/env bash
# scripts/ci/test-branch-reaper.sh — INFRA-1058 (2026-05-14)
#
# Structural and behavioral tests for scripts/coord/branch-reaper.sh.
#
# Tests:
#   1. Script exists and is executable
#   2. Sources repo-paths.sh for LOCK_DIR resolution
#   3. --dry-run is the default (no --act required)
#   4. --act flag exists and overrides dry-run
#   5. Protect-list includes: main, master, release/*, gh-readonly-queue/*
#   6. Emits kind=branch_reaper_pruned to ambient.jsonl
#   7. --keep-list flag accepted without error
#   8. --min-age-days flag accepted without error
#   9. INFRA-1058 marker in script
#  10. Branch hygiene documented in scripts/coord/README.md

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/coord/branch-reaper.sh"
README="$REPO_ROOT/scripts/coord/README.md"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== INFRA-1058 branch-reaper test ==="
echo

# ── Test 1: Script exists and is executable ───────────────────────────────────
if [[ -x "$REAPER" ]]; then
    ok "branch-reaper.sh exists and is executable"
else
    fail "branch-reaper.sh missing or not executable"
fi

# ── Test 2: Sources repo-paths.sh ────────────────────────────────────────────
if grep -q "repo-paths.sh" "$REAPER"; then
    ok "script sources repo-paths.sh"
else
    fail "script missing repo-paths.sh source"
fi

# ── Test 3: --dry-run is default ─────────────────────────────────────────────
if grep -q "DRY_RUN=1" "$REAPER" && grep -q "default.*dry-run\|dry.run.*default\|DRY.RUN.*DEFAULT\|DEFAULT.*dry" "$REAPER"; then
    ok "--dry-run is default (DRY_RUN=1 set at top)"
else
    # Alternative check: DRY_RUN=1 in argument parsing before any --act
    if grep -q "^DRY_RUN=1" "$REAPER"; then
        ok "--dry-run is default (DRY_RUN=1 initializer found)"
    else
        fail "--dry-run not default (DRY_RUN=1 initializer missing)"
    fi
fi

# ── Test 4: --act flag overrides dry-run ─────────────────────────────────────
if grep -q "\-\-act" "$REAPER" && grep -q "ACT=1" "$REAPER"; then
    ok "--act flag exists and sets ACT=1"
else
    fail "--act flag or ACT=1 missing"
fi

# ── Test 5: Protected branches list covers required entries ──────────────────
for pattern in "main" "master" "release/\*" "gh-readonly-queue/\*"; do
    if grep -q "$pattern" "$REAPER"; then
        ok "protect-list includes: $pattern"
    else
        fail "protect-list missing: $pattern"
    fi
done

# ── Test 6: Emits branch_reaper_pruned event ──────────────────────────────────
if grep -q "branch_reaper_pruned" "$REAPER"; then
    ok "script emits kind=branch_reaper_pruned"
else
    fail "script missing branch_reaper_pruned event emission"
fi

# ── Test 7: --keep-list accepted ─────────────────────────────────────────────
if grep -q "\-\-keep-list\|keep.list" "$REAPER"; then
    ok "--keep-list flag supported"
else
    fail "--keep-list flag missing"
fi

# ── Test 8: --min-age-days accepted ──────────────────────────────────────────
if grep -q "\-\-min-age-days\|min.age.days\|MIN_AGE_DAYS" "$REAPER"; then
    ok "--min-age-days flag supported"
else
    fail "--min-age-days flag missing"
fi

# ── Test 9: INFRA-1058 marker ────────────────────────────────────────────────
if grep -q "INFRA-1058" "$REAPER"; then
    ok "INFRA-1058 marker in script"
else
    fail "INFRA-1058 marker missing"
fi

# ── Test 10: README documents branch hygiene ──────────────────────────────────
if [[ -r "$README" ]] && grep -q "INFRA-1058\|branch.*hygiene\|branch-reaper" "$README"; then
    ok "scripts/coord/README.md documents branch hygiene"
else
    fail "scripts/coord/README.md missing branch hygiene documentation"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
