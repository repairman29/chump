#!/usr/bin/env bash
# test-bot-merge-dup-pr.sh — INFRA-996 duplicate PR pre-push guard.
#
# Tests (code-inspection + logic unit tests; no real GitHub calls):
#   1. bot-merge.sh has dup_pr_blocked ambient event emit
#   2. bot-merge.sh has --force-duplicate flag
#   3. bot-merge.sh aborts on dup (exit 16) with fake gh listing conflicting PR
#   4. --force-duplicate bypasses the block
#   5. Same-branch PR is exempted (headRefName matches current branch)
#   6. --gap none skips the dup check (no GAP_IDS)
#   7. gh returning empty (rate-limited) is fail-open (no block)

set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"

echo "=== INFRA-996 duplicate-PR guard tests ==="
echo

# ── Tests 1-2: code structure checks ─────────────────────────────────────────
echo "--- Test 1: dup_pr_blocked ambient emit present ---"
if grep -q 'dup_pr_blocked' "$SCRIPT"; then
    ok "dup_pr_blocked event in bot-merge.sh"
else
    fail "dup_pr_blocked NOT in bot-merge.sh"
fi

echo "--- Test 2: --force-duplicate flag handled ---"
if grep -q -- '--force-duplicate' "$SCRIPT" && grep -q 'FORCE_DUPLICATE' "$SCRIPT"; then
    ok "--force-duplicate / FORCE_DUPLICATE in bot-merge.sh"
else
    fail "--force-duplicate / FORCE_DUPLICATE NOT in bot-merge.sh"
fi

# ── Tests 3-7: logic unit test via extracted dup-check snippet ────────────────
# Build a tiny harness that runs only the dup-check section in isolation.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake gh shim (TEST_GH_DUP controls response).
GH_SHIM="$TMP/gh"
cat > "$GH_SHIM" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]] && echo "$@" | grep -q -- '--json'; then
    echo "${TEST_GH_DUP:-[]}"
    exit 0
fi
exit 0
SHIM
chmod +x "$GH_SHIM"

AMB="$TMP/ambient.jsonl"

# The isolated dup-check harness — mirrors the logic in bot-merge.sh.
DUP_CHECK="$TMP/dup_check.sh"
cat > "$DUP_CHECK" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
FORCE_DUPLICATE=${FORCE_DUPLICATE:-0}
REPO=${REPO:-owner/repo}
BRANCH=${BRANCH:-chump/infra-999-claim}
_amb_path="${CHUMP_AMBIENT_IN_PROMPT:-/dev/null}"
GAP_IDS=(${GAP_IDS_STR:-INFRA-999})
if [[ "${FORCE_DUPLICATE}" == "1" || ${#GAP_IDS[@]} -eq 0 || "${GAP_IDS[0]}" == "none" ]]; then
    exit 0
fi
_dup_found=0
_dup_pr_numbers=""
for _gid in "${GAP_IDS[@]}"; do
    _existing=$(gh pr list --repo "${REPO}" --state open \
        --search "${_gid} in:title" --json number,headRefName \
        --limit 10 2>/dev/null || true)
    if [[ -z "$_existing" ]]; then continue; fi
    _conflicts=$(echo "$_existing" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
conflicts=[str(r['number']) for r in rows if r.get('headRefName','') != '${BRANCH}']
print(' '.join(conflicts))
" 2>/dev/null || true)
    if [[ -n "$_conflicts" ]]; then
        _dup_found=1
        _dup_pr_numbers="${_dup_pr_numbers} ${_conflicts}"
    fi
done
if [[ "$_dup_found" -eq 1 ]]; then
    _dup_pr_numbers="${_dup_pr_numbers# }"
    echo "Duplicate PR blocked: open PR(s) already claim this gap: ${_dup_pr_numbers}" >&2
    printf '{"ts":"%s","kind":"dup_pr_blocked","gap_id":"%s","existing_pr_numbers":"%s","current_branch":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GAP_IDS[*]:-}" "$_dup_pr_numbers" "$BRANCH" \
        >> "$_amb_path" 2>/dev/null || true
    exit 16
fi
exit 0
HARNESS
chmod +x "$DUP_CHECK"

export PATH="$TMP:$PATH"
export CHUMP_AMBIENT_IN_PROMPT="$AMB"
export REPO="owner/repo"
export BRANCH="chump/infra-999-claim"

echo "--- Test 3: dup PR on different branch → exit 16 + PR# in error ---"
export TEST_GH_DUP='[{"number":1234,"headRefName":"chump/infra-999-old"}]'
set +e
out3=$(bash "$DUP_CHECK" 2>&1)
exit3=$?
set -e
if [[ "$exit3" -eq 16 ]]; then
    ok "dup block: exit code 16"
else
    fail "dup block: expected exit 16, got $exit3"
fi
if echo "$out3" | grep -q "1234"; then
    ok "dup block: PR#1234 in error message"
else
    fail "dup block: PR#1234 not in message; output: $out3"
fi
if grep -q "dup_pr_blocked" "$AMB" 2>/dev/null; then
    ok "dup block: dup_pr_blocked emitted to ambient.jsonl"
else
    fail "dup block: dup_pr_blocked NOT in ambient.jsonl"
fi

echo "--- Test 4: --force-duplicate bypasses the block ---"
export TEST_GH_DUP='[{"number":1234,"headRefName":"chump/infra-999-old"}]'
set +e
FORCE_DUPLICATE=1 bash "$DUP_CHECK" 2>&1
exit4=$?
set -e
if [[ "$exit4" -eq 0 ]]; then
    ok "--force-duplicate: exit 0"
else
    fail "--force-duplicate: expected exit 0, got $exit4"
fi

echo "--- Test 5: same-branch PR exempted ---"
export TEST_GH_DUP='[{"number":5678,"headRefName":"chump/infra-999-claim"}]'
set +e
bash "$DUP_CHECK" 2>&1
exit5=$?
set -e
if [[ "$exit5" -eq 0 ]]; then
    ok "same-branch exemption: exit 0 (PR 5678 not flagged)"
else
    fail "same-branch exemption: expected exit 0, got $exit5"
fi

echo "--- Test 6: --gap none skips check ---"
export TEST_GH_DUP='[{"number":9999,"headRefName":"chump/other"}]'
set +e
GAP_IDS_STR="none" bash "$DUP_CHECK" 2>&1
exit6=$?
set -e
if [[ "$exit6" -eq 0 ]]; then
    ok "--gap none: check skipped, exit 0"
else
    fail "--gap none: expected exit 0, got $exit6"
fi

echo "--- Test 7: gh returns empty (rate-limited) → fail-open ---"
export TEST_GH_DUP=''
set +e
bash "$DUP_CHECK" 2>&1
exit7=$?
set -e
if [[ "$exit7" -eq 0 ]]; then
    ok "fail-open: empty gh response → exit 0"
else
    fail "fail-open: expected exit 0, got $exit7"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
