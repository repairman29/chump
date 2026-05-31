#!/usr/bin/env bash
# test-pwa-flake-quarantine.sh — INFRA-1332
#
# Verifies the playwright quarantine wiring:
#   1. The 3 flaky describe blocks have test.skip(!INCLUDE_PWA_FLAKES, ...)
#   2. INCLUDE_PWA_FLAKES is derived from CHUMP_E2E_INCLUDE_FLAKES env
#   3. docs/process/KNOWN_FLAKES.yaml has playwright_flakes section with
#      tracking_gap for each describe
#   4. .github/workflows/e2e-pwa-advisory.yml exists + sets the env

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-1332 PWA flake quarantine tests ==="

SPEC="$REPO_ROOT/e2e/tests/api-and-pwa.spec.ts"
CATALOG="$REPO_ROOT/docs/process/KNOWN_FLAKES.yaml"
# META-266 (2026-05-31, PR #2904): e2e-pwa-advisory.yml was collapsed into
# integrations.yml as the e2e-pwa-flakes job. Point at the new home.
WORKFLOW="$REPO_ROOT/.github/workflows/integrations.yml"

[[ -f "$SPEC" ]] || { fail "spec file missing"; exit 1; }
ok "spec file present"

# ── Test 1: each of 3 describes has test.skip guard ──────────────────────────
for d in "PWA shell" "PWA mobile viewport" "Chat /task"; do
    # Match the describe declaration then look at the next few lines for test.skip
    if grep -A2 "test\\.describe('$d" "$SPEC" 2>/dev/null | grep -q 'test.skip(!INCLUDE_PWA_FLAKES'; then
        ok "describe '$d' has test.skip(!INCLUDE_PWA_FLAKES, ...)"
    else
        fail "describe '$d' missing test.skip guard"
    fi
done

# ── Test 2: INCLUDE_PWA_FLAKES const reads CHUMP_E2E_INCLUDE_FLAKES ──────────
if grep -q "const INCLUDE_PWA_FLAKES = process.env.CHUMP_E2E_INCLUDE_FLAKES === '1'" "$SPEC"; then
    ok "INCLUDE_PWA_FLAKES reads CHUMP_E2E_INCLUDE_FLAKES env"
else
    fail "env wire missing"
fi

# ── Test 3: KNOWN_FLAKES.yaml has playwright_flakes section ──────────────────
if grep -q '^playwright_flakes:' "$CATALOG"; then
    ok "KNOWN_FLAKES.yaml has playwright_flakes: section"
else
    fail "playwright_flakes section missing from catalog"
fi

# ── Test 4: every playwright_flakes entry has a tracking_gap ────────────────
python3 -c "
import sys, yaml
data = yaml.safe_load(open('$CATALOG'))
flakes = data.get('playwright_flakes') or []
if not flakes:
    print('  FAIL: playwright_flakes empty')
    sys.exit(1)
missing = [f.get('describe','?') for f in flakes if not f.get('tracking_gap')]
if missing:
    print(f'  FAIL: entries missing tracking_gap: {missing}')
    sys.exit(1)
print(f'  PASS: all {len(flakes)} playwright_flakes entries have tracking_gap')
" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILS+=("playwright_flakes tracking_gap"); }

# ── Test 5: advisory workflow exists + has correct env ──────────────────────
if [[ -f "$WORKFLOW" ]]; then
    ok "advisory workflow present"
    if grep -q 'CHUMP_E2E_INCLUDE_FLAKES.*"1"' "$WORKFLOW"; then
        ok "advisory workflow sets CHUMP_E2E_INCLUDE_FLAKES=1"
    else
        fail "advisory workflow missing CHUMP_E2E_INCLUDE_FLAKES=1"
    fi
    if grep -q 'continue-on-error: true' "$WORKFLOW"; then
        ok "advisory workflow has continue-on-error: true (non-blocking)"
    else
        fail "advisory workflow missing continue-on-error (would block merges)"
    fi
else
    fail "advisory workflow missing: $WORKFLOW"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
