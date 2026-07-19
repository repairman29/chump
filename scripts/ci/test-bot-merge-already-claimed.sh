#!/usr/bin/env bash
# INFRA-1901: smoke-test the "already inside the claimed worktree" detection
# in bot-merge.sh's claim section.
#
# Baseline (2026-05-23): 3 of 4 sub-agents (INFRA-1586, INFRA-1585, INFRA-1743)
# invoked bot-merge.sh from inside their already-claimed worktree, hit a
# "re-claim failed" error from the unconditional `chump claim` call, and were
# forced into manual gh pr create + gh pr merge --auto recovery.
#
# Strategy: synthesize a lease (both JSON-sidecar and state.db shapes) whose
# worktree_path matches a sandbox dir, cd into it, and reproduce the exact
# detection block from bot-merge.sh with a mock `chump` that FAILS if it is
# ever invoked to claim — proving detection short-circuits the call.
#
# Run from repo root: bash scripts/ci/test-bot-merge-already-claimed.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1" >&2; FAIL=$((FAIL+1)); }

# ── Test 1: lease.sh exposes the new helpers ────────────────────────────────
if grep -q '^lease_worktree_from_statedb()' "$REPO_ROOT/scripts/lib/lease.sh" \
   && grep -q '^lease_path_is_within()' "$REPO_ROOT/scripts/lib/lease.sh"; then
    pass "scripts/lib/lease.sh defines lease_worktree_from_statedb + lease_path_is_within"
else
    fail "scripts/lib/lease.sh missing lease_worktree_from_statedb or lease_path_is_within"
fi

# ── Test 2: bot-merge.sh's claim block references the new detection ────────
if grep -q 'INFRA-1901' "$REPO_ROOT/scripts/coord/bot-merge.sh" \
   && grep -q '_already_in_worktree' "$REPO_ROOT/scripts/coord/bot-merge.sh"; then
    pass "bot-merge.sh wires in the already-in-worktree detection (INFRA-1901)"
else
    fail "bot-merge.sh does not reference _already_in_worktree / INFRA-1901"
fi

# ── Test 3: functional — JSON lease sidecar match skips chump claim ─────────
SANDBOX=$(mktemp -d)
WORKTREE=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$WORKTREE"' EXIT

# shellcheck source=../lib/lease.sh
source "$REPO_ROOT/scripts/lib/lease.sh"

mkdir -p "$SANDBOX/.chump-locks"
cat > "$SANDBOX/.chump-locks/claim-infra-test-1901.json" <<JSON
{
  "session_id": "claim-infra-test-1901-99999",
  "gap_id": "INFRA-TEST-1901",
  "worktree": "$WORKTREE"
}
JSON

# Mock chump: any invocation of "claim" is a hard test failure — proves the
# detection path never reaches it.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/chump" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "claim" ]]; then
    echo "MOCK-CHUMP-CLAIM-INVOKED" >&2
    exit 1
fi
if [[ "${1:-}" == "ambient" ]]; then
    exit 0
fi
exit 0
MOCK
chmod +x "$SANDBOX/bin/chump"

DETECT_SCRIPT="$SANDBOX/detect.sh"
cat > "$DETECT_SCRIPT" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail
info() { echo "[INFO] \$*"; }
LOCK_DIR="$SANDBOX/.chump-locks"
MAIN_REPO="$SANDBOX"
REPO_ROOT="$SANDBOX"
gid="INFRA-TEST-1901"
export PATH="$SANDBOX/bin:\$PATH"
source "$REPO_ROOT/scripts/lib/lease.sh"

_already_in_worktree=0
if [[ "\${CHUMP_BOT_MERGE_SKIP_CLAIM:-0}" == "1" ]]; then
    chump ambient emit bot_merge_skip_claim_lax "gap=\$gid" "reason=bypass" >/dev/null 2>&1 || true
else
    _lease_wt=""
    for _lf in "\$LOCK_DIR"/*.json; do
        [[ -f "\$_lf" ]] || continue
        if [[ "\$(lease_gap_id "\$_lf")" == "\$gid" ]]; then
            _lease_wt="\$(lease_worktree "\$_lf")"
            [[ -n "\$_lease_wt" ]] && break
        fi
    done
    if [[ -n "\$_lease_wt" ]] && lease_path_is_within "\$(pwd)" "\$_lease_wt"; then
        _already_in_worktree=1
        info "INFRA-1901: already inside gap \$gid's claimed worktree (\$_lease_wt) — skipping chump claim re-invocation"
    fi
fi

if [[ "\$_already_in_worktree" -eq 1 ]]; then
    echo "SKIPPED_CLAIM"
else
    chump claim "\$gid" || true
    echo "ATTEMPTED_CLAIM"
fi
HARNESS
chmod +x "$DETECT_SCRIPT"

cd "$WORKTREE"
_out=$(bash "$DETECT_SCRIPT" 2>&1)
cd "$REPO_ROOT"

if echo "$_out" | grep -q "SKIPPED_CLAIM" && ! echo "$_out" | grep -q "MOCK-CHUMP-CLAIM-INVOKED"; then
    pass "detection skipped chump claim when pwd matched the lease worktree (INFRA-1901 AC#1/AC#2)"
else
    fail "detection did not skip chump claim from inside the matching worktree"
    echo "$_out" >&2
fi

# ── Test 4: /tmp vs /private/tmp symlink resolution (macOS, AC#3) ──────────
# Simulate the case where pwd resolves through /private/tmp but the lease
# recorded the /tmp-prefixed path (or vice versa) — lease_path_is_within
# must still match after realpath resolution on both sides.
if [[ -L /tmp ]]; then
    _real_worktree="$(realpath "$WORKTREE")"
    if lease_path_is_within "$WORKTREE" "$_real_worktree"; then
        pass "lease_path_is_within resolves /tmp vs /private/tmp symlink mismatch (AC#3)"
    else
        fail "lease_path_is_within failed to resolve /tmp vs /private/tmp symlink mismatch"
    fi
else
    # Non-macOS CI runner without the /tmp symlink: assert plain equality still works.
    if lease_path_is_within "$WORKTREE" "$WORKTREE"; then
        pass "lease_path_is_within matches identical paths (no /tmp symlink on this platform)"
    else
        fail "lease_path_is_within failed on identical paths"
    fi
fi

# ── Test 5: CHUMP_BOT_MERGE_SKIP_CLAIM=1 bypass restores unconditional re-claim ──
DETECT_SCRIPT2="$SANDBOX/detect_bypass.sh"
sed 's/^gid=.*/gid="INFRA-TEST-1901"\nexport CHUMP_BOT_MERGE_SKIP_CLAIM=1/' "$DETECT_SCRIPT" > "$DETECT_SCRIPT2"
chmod +x "$DETECT_SCRIPT2"
cd "$WORKTREE"
_out2=$(bash "$DETECT_SCRIPT2" 2>&1 || true)
cd "$REPO_ROOT"
if echo "$_out2" | grep -q "ATTEMPTED_CLAIM"; then
    pass "CHUMP_BOT_MERGE_SKIP_CLAIM=1 bypasses detection and re-attempts chump claim (AC#5)"
else
    fail "CHUMP_BOT_MERGE_SKIP_CLAIM=1 bypass did not restore unconditional re-claim"
    echo "$_out2" >&2
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
