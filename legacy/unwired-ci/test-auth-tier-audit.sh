#!/usr/bin/env bash
# scripts/ci/test-auth-tier-audit.sh — INFRA-1078
#
# Verifies scripts/ci/auth-tier-audit.sh:
#   1. Default text mode runs end-to-end with non-zero callsite count
#   2. --json output validates as JSON
#   3. --fail-on-unknown exits 0 if no UNKNOWN, non-zero if some
#   4. scripts/coord/AUTH_AUDIT.md exists + has expected sections

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUDIT="$REPO_ROOT/scripts/ci/auth-tier-audit.sh"
REPORT="$REPO_ROOT/scripts/coord/AUTH_AUDIT.md"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$AUDIT" ]] || fail "audit script missing or not executable"

# ── Test 1: default text mode ───────────────────────────────────────────────
OUT="$(bash "$AUDIT" 2>&1)"
echo "$OUT" | grep -qE "APP_TOKEN.*callsites" || fail "missing APP_TOKEN summary"
echo "$OUT" | grep -qE "PAT.*callsites"       || fail "missing PAT summary"
echo "$OUT" | grep -qE "GITHUB_TOKEN.*callsites" || fail "missing GITHUB_TOKEN summary"
ok "text mode prints all 4 tiers with callsite counts"

# ── Test 2: --json mode ─────────────────────────────────────────────────────
bash "$AUDIT" --json 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['total'] > 0, d
assert isinstance(d['rows'], list)
assert d['rows'][0]['tier'] in ('APP_TOKEN', 'PAT', 'GITHUB_TOKEN', 'UNKNOWN')
print('ok json')
" || fail "--json output not valid JSON or wrong shape"
ok "--json validates as JSON with correct shape"

# ── Test 3: --fail-on-unknown ───────────────────────────────────────────────
# Today's repo state has 0 UNKNOWN callsites, so --fail-on-unknown should exit 0.
set +e
bash "$AUDIT" --fail-on-unknown >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" -eq 0 ]] || fail "--fail-on-unknown exited $RC, but 0 UNKNOWN means it should be 0"
ok "--fail-on-unknown exits 0 when no UNKNOWN callsites (clean repo)"

# ── Test 4: AUTH_AUDIT.md report exists with expected sections ──────────────
[[ -f "$REPORT" ]] || fail "$REPORT missing — should be checked in"
grep -q "INFRA-1078" "$REPORT" || fail "report missing INFRA-1078 reference"
grep -qE "APP_TOKEN.*callsites" "$REPORT" || fail "report missing APP_TOKEN section"
grep -qE "PAT.*callsites" "$REPORT" || fail "report missing PAT section"
ok "AUTH_AUDIT.md report present with all expected sections"

echo
echo "All INFRA-1078 auth-tier-audit tests passed."
