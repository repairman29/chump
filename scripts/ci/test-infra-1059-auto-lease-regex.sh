#!/usr/bin/env bash
# INFRA-1059: verify chump-commit auto-lease regex ignores non-gap tokens.
#
# Tests:
#   1. SHA-256 / P0-1 / HTTP-200 do NOT trigger gap-claim.sh invocations
#   2. Real gap-IDs (INFRA-127, COG-040) still extracted
#   3. gap-claim.sh bails fast on non-gap tokens (exit 0, message to stderr)
#   4. Mixed commit message: only real IDs extracted

set -eu
# Use the directory containing this script to locate siblings — avoids
# INFRA-779 show-toplevel corruption that makes git rev-parse --show-toplevel
# return the main repo path instead of this worktree.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

COMMIT_SH="$REPO_ROOT/scripts/coord/chump-commit.sh"
CLAIM_SH="$REPO_ROOT/scripts/coord/gap-claim.sh"

# ── Test 1-3: gap-claim.sh bails fast on non-gap tokens ──────────────────────
for bad_id in "SHA-256" "P0-1" "HTTP-200" "UTF-8" "AES-128" "RSA-4096"; do
    out=$(bash "$CLAIM_SH" "$bad_id" 2>&1 || true)
    if echo "$out" | grep -q "non-gap token"; then
        pass "gap-claim.sh: '$bad_id' → bail-fast (non-gap token)"
    else
        fail "gap-claim.sh: '$bad_id' should bail fast, got: $out"
    fi
done

# ── Test 4: real gap-IDs pass the domain-prefix check ────────────────────────
# We can't call gap-claim.sh for real (it would try to create worktrees), so
# just verify the domain regex matches them.
_KNOWN_DOMAIN_RE='^(INFRA|CREDIBLE|EFFECTIVE|RESILIENT|EVAL|COG|DOC|FLEET|META|PRODUCT|SMOKE|ACP|AGT|AUTO|COMP|FRONTIER|MEM|QUALITY|RELIABILITY|RESEARCH|SECURITY|SENSE|SWARM|UX|TEST)-[0-9]+$'
for good_id in "INFRA-127" "COG-040" "EVAL-101" "DOC-013" "META-028" "FLEET-034"; do
    if echo "$good_id" | grep -qE "$_KNOWN_DOMAIN_RE"; then
        pass "regex: '$good_id' → accepted"
    else
        fail "regex: '$good_id' should be accepted but was rejected"
    fi
done

# ── Test 5: chump-commit.sh regex extraction skips non-gap tokens ────────────
# Simulate the extraction logic from chump-commit.sh using dynamic prefix derivation.
_state_db="$REPO_ROOT/.chump/state.db"
_known_prefixes=""
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_state_db" ]]; then
    _known_prefixes=$(sqlite3 "$_state_db" \
        "SELECT DISTINCT substr(id,1,instr(id,'-')-1) FROM gaps;" 2>/dev/null \
        | tr '\n' '|' | sed 's/|$//')
fi
if [[ -z "$_known_prefixes" ]]; then
    _known_prefixes="INFRA|CREDIBLE|EFFECTIVE|RESILIENT|EVAL|COG|DOC|FLEET|META|PRODUCT|SMOKE"
fi

_test_msg="feat(INFRA-127): fix something SHA-256 hashed; closes COG-040; HTTP-200 ok; P0-1 concern"
_extracted=$(echo "$_test_msg" | grep -oE "(${_known_prefixes})-[0-9]+" | sort -u || true)

if echo "$_extracted" | grep -q "INFRA-127" && echo "$_extracted" | grep -q "COG-040"; then
    pass "extraction: real IDs (INFRA-127, COG-040) present in output"
else
    fail "extraction: expected INFRA-127 and COG-040, got: $_extracted"
fi

if echo "$_extracted" | grep -qE "SHA-256|P0-1|HTTP-200"; then
    fail "extraction: non-gap tokens leaked into result: $_extracted"
else
    pass "extraction: SHA-256, P0-1, HTTP-200 not in output"
fi

echo
echo "===== INFRA-1059 results: $PASS pass, $FAIL fail ====="
[[ $FAIL -eq 0 ]]
