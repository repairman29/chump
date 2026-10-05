#!/usr/bin/env bash
# test-cascade-rebase-observability.sh — INFRA-1648
#
# Verifies the cascade-rebase observability additions on top of the
# INFRA-1458 machinery:
#   1. Success path emits kind=cascade_rebase_pr_result with result=success
#   2. A hung call is bounded by the 30s-equivalent budget and reported as
#      result=timeout, failure_class=transient (rc=124 semantics)
#   3. A permanent failure (semantic conflict / not-found style stderr) is
#      classified failure_class=permanent
#   4. A transient failure (network blip / secondary rate limit style
#      stderr) is classified failure_class=transient
#   5. cascade_rebase_triggered carries duration_s + timeout_count fields
#
# This test extracts the real _cascade_run_with_timeout, _cascade_classify_failure,
# and _cascade_emit_pr_result functions out of queue-driver.sh (rather than
# reimplementing them) so a regression in the actual implementation fails
# this test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

QUEUE_DRIVER="$REPO_ROOT/scripts/coord/queue-driver.sh"
[[ -f "$QUEUE_DRIVER" ]] || fail "queue-driver.sh missing: $QUEUE_DRIVER"

TMP="$(mktemp -d -t infra1648-test-XXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── Extract the 3 functions under test verbatim from queue-driver.sh ──────
FUNCS_FILE="$TMP/funcs.sh"
for fn in _cascade_run_with_timeout _cascade_classify_failure _cascade_emit_pr_result; do
    awk -v fn="$fn" '
        $0 ~ "^" fn "\\(\\)" { found=1 }
        found { print }
        found && /^}/ { found=0; exit_after=1 }
    ' "$QUEUE_DRIVER" >> "$FUNCS_FILE"
    echo "" >> "$FUNCS_FILE"
done

for fn in _cascade_run_with_timeout _cascade_classify_failure _cascade_emit_pr_result; do
    grep -q "^${fn}()" "$FUNCS_FILE" || fail "extraction failed for $fn — queue-driver.sh shape changed?"
done

FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.chump-locks"
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"
touch "$AMBIENT"

# ── Test 1: success path ───────────────────────────────────────────────────
bash -c "
    set -euo pipefail
    REPO_ROOT='$FAKE_REPO'
    source '$FUNCS_FILE'
    source '$REPO_ROOT/scripts/coord/lib/ambient-write.sh'
    _cascade_emit_pr_result 4242 success update_branch '' 850
"
result1=$(grep '"pr":4242' "$AMBIENT" | tail -1)
echo "$result1" | grep -q '"result":"success"' || fail "Test 1: expected result=success, got: $result1"
echo "$result1" | grep -q '"failure_class":""' || fail "Test 1: expected empty failure_class on success, got: $result1"
ok "Test 1: success path emits cascade_rebase_pr_result with result=success"

# ── Test 2: timeout bound + classification ─────────────────────────────────
# _cascade_run_with_timeout budget=1s wrapping a 5s sleep must return 124.
rc=0
bash -c "
    set -euo pipefail
    source '$FUNCS_FILE'
    _cascade_run_with_timeout 1 sleep 5
" || rc=$?
[[ "$rc" -eq 124 ]] || fail "Test 2: expected rc=124 on timeout, got $rc"
ok "Test 2: _cascade_run_with_timeout enforces the wall-clock budget (rc=124)"

class_timeout=$(bash -c "source '$FUNCS_FILE'; _cascade_classify_failure 124 ''")
[[ "$class_timeout" == "transient" ]] || fail "Test 2b: expected transient for rc=124, got $class_timeout"
ok "Test 2b: rc=124 (timeout) classifies as transient"

# ── Test 3: permanent failure classification ────────────────────────────────
class_perm=$(bash -c "source '$FUNCS_FILE'; _cascade_classify_failure 1 'GraphQL: Could not resolve to a PullRequest (pull request already merged)'")
[[ "$class_perm" == "permanent" ]] || fail "Test 3: expected permanent for already-merged error, got $class_perm"
ok "Test 3: 'already merged' failure classifies as permanent"

# ── Test 4: transient failure classification ────────────────────────────────
class_trans=$(bash -c "source '$FUNCS_FILE'; _cascade_classify_failure 1 'error connecting: Could not resolve host: api.github.com'")
[[ "$class_trans" == "transient" ]] || fail "Test 4: expected transient for network error, got $class_trans"
ok "Test 4: network-error failure classifies as transient"

# ── Test 5: cascade_rebase_triggered carries duration_s + timeout_count ────
grep -n 'kind":"cascade_rebase_triggered' "$QUEUE_DRIVER" >/dev/null 2>&1 || true
grep -q '"duration_s":%d' "$QUEUE_DRIVER" || fail "Test 5: cascade_rebase_triggered emit is missing duration_s field"
grep -q '"timeout_count":%d' "$QUEUE_DRIVER" || fail "Test 5: cascade_rebase_triggered emit is missing timeout_count field"
ok "Test 5: cascade_rebase_triggered format string carries duration_s + timeout_count"

echo ""
echo "=== test-cascade-rebase-observability.sh PASSED ==="
