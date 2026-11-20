#!/usr/bin/env bash
# CI test: INFRA-1413 — auto-delete PR branches on merge.
# Verifies:
#   1. bot-merge.sh REST-direct path includes INFRA-1413 branch deletion fallback
#   2. The fallback logic: check if branch exists, delete if present, skip if absent
#   3. Ambient event emitted on fallback deletion

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1413 branch-delete-on-merge test ==="
echo

# ── 1. Structural checks on bot-merge.sh ────────────────────────────────────
if grep -q "INFRA-1413" "$BOT_MERGE"; then
    ok "bot-merge.sh references INFRA-1413"
else
    fail "bot-merge.sh missing INFRA-1413 marker"
fi

if grep -q 'refs/heads.*BRANCH\|BRANCH.*refs/heads' "$BOT_MERGE"; then
    ok "bot-merge.sh builds _bdom_ref from BRANCH"
else
    fail "bot-merge.sh missing _bdom_ref construction"
fi

if grep -qE 'gh api.*-X DELETE' "$BOT_MERGE" && grep -q '_bdom_ref' "$BOT_MERGE"; then
    ok "bot-merge.sh contains gh api ... -X DELETE fallback using _bdom_ref"
else
    fail "bot-merge.sh missing gh api -X DELETE or _bdom_ref for branch cleanup"
fi

if grep -q 'branch_deleted_fallback' "$BOT_MERGE"; then
    ok "bot-merge.sh emits kind=branch_deleted_fallback to ambient"
else
    fail "bot-merge.sh missing kind=branch_deleted_fallback ambient event"
fi

if grep -q 'already deleted by repo setting' "$BOT_MERGE"; then
    ok "bot-merge.sh handles already-deleted (repo-setting) case"
else
    fail "bot-merge.sh missing already-deleted log message"
fi

# The fallback must be inside the _rest_direct_merged=1 block (not global).
# Verify it appears between the REST-direct merge API call and the 'else' for fallback to auto-merge.
_bdom_line=$(grep -n "INFRA-1413" "$BOT_MERGE" | head -1 | cut -d: -f1)
_rest_merged_line=$(grep -n "_rest_direct_merged=1" "$BOT_MERGE" | head -1 | cut -d: -f1)
if [[ -n "$_bdom_line" && -n "$_rest_merged_line" && "$_bdom_line" -gt "$_rest_merged_line" ]]; then
    ok "INFRA-1413 fallback appears after _rest_direct_merged=1 (inside merge-success block)"
else
    fail "INFRA-1413 fallback not positioned inside REST-direct merge success block (expected line > $_rest_merged_line, got $_bdom_line)"
fi

# ── 2. Stub functional test: branch exists → delete path ────────────────────
echo
echo "--- Stub: branch exists → fallback delete fires ---"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMB="$TMPDIR_TEST/ambient.jsonl"
GH_LOG="$TMPDIR_TEST/gh_calls.log"
touch "$AMB" "$GH_LOG"

# Write a self-contained test harness that reproduces the INFRA-1413 logic
# with stub gh (avoids eval of multi-level quoting in the original snippet).
cat > "$TMPDIR_TEST/run_bdom.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
BRANCH="$1" _rd_nwo="$2" _rd_amb="$3" TARGET_PR="$4"
_bdom_ref="refs/heads/${BRANCH}"
if gh api "repos/${_rd_nwo}/git/${_bdom_ref}" >/dev/null 2>&1; then
    if gh api "repos/${_rd_nwo}/git/${_bdom_ref}" -X DELETE >/dev/null 2>&1; then
        printf '{"ts":"%s","kind":"branch_deleted_fallback","pr":%s,"branch":"%s","note":"INFRA-1413"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET_PR" "$BRANCH" >> "$_rd_amb" 2>/dev/null || true
    fi
else
    echo "already deleted by repo setting"
fi
HARNESS
chmod +x "$TMPDIR_TEST/run_bdom.sh"

# Stub gh: GET → 0 (branch exists); DELETE → 0 (success)
cat > "$TMPDIR_TEST/gh" <<GHSTUB
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
exit 0
GHSTUB
chmod +x "$TMPDIR_TEST/gh"

PATH="$TMPDIR_TEST:$PATH" bash "$TMPDIR_TEST/run_bdom.sh" \
    "chump/infra-1413-test" "repairman29/chump" "$AMB" "9999" 2>/dev/null || true

if grep -q "refs/heads/chump/infra-1413-test" "$GH_LOG" 2>/dev/null; then
    ok "stub: GET refs/heads/<branch> call issued"
else
    fail "stub: GET refs/heads/<branch> call not seen in gh log (got: $(cat "$GH_LOG" 2>/dev/null || echo '(empty)'))"
fi

if grep -q "\-X DELETE" "$GH_LOG" 2>/dev/null; then
    ok "stub: DELETE call issued (branch existed)"
else
    fail "stub: DELETE call not issued"
fi

if grep -q "branch_deleted_fallback" "$AMB" 2>/dev/null; then
    ok "stub: kind=branch_deleted_fallback emitted to ambient"
else
    fail "stub: kind=branch_deleted_fallback not in ambient"
fi

# ── 3. Stub functional test: branch already gone → skip path ────────────────
echo
echo "--- Stub: branch already deleted → no DELETE call ---"

GH_LOG2="$TMPDIR_TEST/gh_calls2.log"
touch "$GH_LOG2"

# Stub gh: GET → 1 (branch absent); DELETE would be 0 but should not be called
cat > "$TMPDIR_TEST/gh" <<GHSTUB2
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG2"
if [[ "\$*" == *"-X DELETE"* ]]; then exit 0; fi
exit 1
GHSTUB2
chmod +x "$TMPDIR_TEST/gh"

AMB2="$TMPDIR_TEST/ambient2.jsonl"; touch "$AMB2"
PATH="$TMPDIR_TEST:$PATH" bash "$TMPDIR_TEST/run_bdom.sh" \
    "chump/infra-1413-test" "repairman29/chump" "$AMB2" "9999" 2>/dev/null || true

if ! grep -q "\-X DELETE" "$GH_LOG2" 2>/dev/null; then
    ok "stub: DELETE not issued when branch already absent"
else
    fail "stub: DELETE erroneously issued when branch was already gone"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
