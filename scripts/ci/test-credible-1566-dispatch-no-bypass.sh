#!/usr/bin/env bash
# scripts/ci/test-credible-1566-dispatch-no-bypass.sh — CREDIBLE-1566 regression.
#
# Verifies:
#   1. Inside a dispatch (CHUMP_DISPATCH_GAP set), pre-push refuses CHUMP_TEST_GATE=0
#      and a Test-Gate-Bypass: trailer, exits non-zero, and emits kind=agent_bypass_refused.
#   2. Outside a dispatch, the same push keeps operator bypass behaviour (exits 0).
#   3. Inside a dispatch, commit-msg refuses Test-Gate-Bypass: / Off-Rails-Bypass: trailers
#      and emits kind=agent_bypass_refused.
#   4. A repair lease recording the PR's head branch passes Guard 5 (Off-Rails) without a trailer.
#   5. Mutant that drops the dispatch check in pre-push fails the test.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRE_PUSH="$REPO_ROOT/scripts/git-hooks/pre-push"
COMMIT_MSG="$REPO_ROOT/scripts/git-hooks/commit-msg"

echo "=== CREDIBLE-1566: dispatched agents cannot bypass test gate or Off-Rails ==="

T="$(mktemp -d "${TMPDIR:-/tmp}/credible-1566.XXXXXX")"
trap 'rm -rf "$T"' EXIT

git init -q -b main "$T/repo"
git -C "$T/repo" config user.email "test@example.com"
git -C "$T/repo" config user.name "Test"
mkdir -p "$T/repo/scripts/git-hooks" "$T/repo/.chump-locks"
cp "$PRE_PUSH" "$T/repo/scripts/git-hooks/pre-push"
cp "$COMMIT_MSG" "$T/repo/scripts/git-hooks/commit-msg"
chmod +x "$T/repo/scripts/git-hooks/pre-push" "$T/repo/scripts/git-hooks/commit-msg"

echo "init" > "$T/repo/f.txt"
git -C "$T/repo" add f.txt
git -C "$T/repo" commit -q -m "init"
git clone -q --bare "$T/repo" "$T/origin.git"
git -C "$T/repo" remote add origin "$T/origin.git"
git -C "$T/repo" fetch -q origin main
base_sha="$(git -C "$T/repo" rev-parse HEAD)"

git -C "$T/repo" checkout -q -b claude/infra-8595
echo "work" > "$T/repo/f.txt"
git -C "$T/repo" add f.txt
git -C "$T/repo" commit -q -m "fix(infra): repair slice"
clean_sha="$(git -C "$T/repo" rev-parse HEAD)"

# 1. Inside dispatch: CHUMP_TEST_GATE=0 is refused by pre-push
rm -f "$T/repo/.chump-locks/ambient.jsonl"
rc=0
(
    cd "$T/repo" &&     CHUMP_DISPATCH_GAP="INFRA-8597"     CHUMP_TEST_GATE=0     bash "$T/repo/scripts/git-hooks/pre-push" origin "$T/origin.git"         <<< "refs/heads/claude/infra-8595 $clean_sha refs/heads/claude/infra-8595 $base_sha"
) >"$T/out1" 2>&1 || rc=$?
amb="$(cat "$T/repo/.chump-locks/ambient.jsonl" 2>/dev/null || true)"
if [[ "$rc" -ne 0 ]] && grep -q '"kind":"agent_bypass_refused"' <<<"$amb"; then
    ok "inside dispatch, CHUMP_TEST_GATE=0 is refused (rc=$rc) and emits agent_bypass_refused"
else
    fail "inside dispatch, CHUMP_TEST_GATE=0 should be refused: rc=$rc amb='$amb' out=$(cat "$T/out1")"
fi

# 2. Inside dispatch: commit-msg refuses Test-Gate-Bypass: trailer
printf 'fix: test

Test-Gate-Bypass: unrelated red test
' > "$T/msg.txt"
rm -f "$T/repo/.chump-locks/ambient.jsonl"
cm_rc=0
(
    cd "$T/repo" &&     CHUMP_DISPATCH_GAP="INFRA-8597"     bash "$T/repo/scripts/git-hooks/commit-msg" "$T/msg.txt"
) >"$T/cm.out" 2>&1 || cm_rc=$?
amb="$(cat "$T/repo/.chump-locks/ambient.jsonl" 2>/dev/null || true)"
if [[ "$cm_rc" -ne 0 ]] && grep -q '"kind":"agent_bypass_refused"' <<<"$amb"; then
    ok "inside dispatch, commit-msg refuses Test-Gate-Bypass: trailer and emits agent_bypass_refused"
else
    fail "inside dispatch, commit-msg should refuse Test-Gate-Bypass: rc=$cm_rc amb='$amb'"
fi

# 3. Inside dispatch: pre-push refuses commit carrying Test-Gate-Bypass: trailer
git -C "$T/repo" commit -q --amend -m $'fix(infra): repair slice

Test-Gate-Bypass: unrelated red test'
trailer_sha="$(git -C "$T/repo" rev-parse HEAD)"
rm -f "$T/repo/.chump-locks/ambient.jsonl"
rc=0
(
    cd "$T/repo" &&     CHUMP_DISPATCH_GAP="INFRA-8597"     bash "$T/repo/scripts/git-hooks/pre-push" origin "$T/origin.git"         <<< "refs/heads/claude/infra-8595 $trailer_sha refs/heads/claude/infra-8595 $base_sha"
) >"$T/out2" 2>&1 || rc=$?
amb="$(cat "$T/repo/.chump-locks/ambient.jsonl" 2>/dev/null || true)"
if [[ "$rc" -ne 0 ]] && grep -q '"kind":"agent_bypass_refused"' <<<"$amb"; then
    ok "inside dispatch, pre-push refuses Test-Gate-Bypass: trailer and emits agent_bypass_refused"
else
    fail "inside dispatch, pre-push should refuse Test-Gate-Bypass: rc=$rc amb='$amb'"
fi

# 4. Outside dispatch (operator): CHUMP_TEST_GATE=0 + Test-Gate-Bypass: succeeds
#    and repair lease with explicit branch claude/infra-8595 passes Guard 5 without Off-Rails-Bypass
cat > "$T/repo/.chump-locks/claim-infra-8597.json" <<'JSON'
{
  "session_id": "sess-repair",
  "paths": [],
  "taken_at": "2026-01-01T00:00:00Z",
  "expires_at": "2099-01-01T00:00:00Z",
  "heartbeat_at": "2026-01-01T00:00:00Z",
  "purpose": "dispatch",
  "worktree": "",
  "gap_id": "INFRA-8597",
  "branch": "claude/infra-8595"
}
JSON
git -C "$T/repo" commit -q --amend -m "fix(infra): repair slice"
clean_sha="$(git -C "$T/repo" rev-parse HEAD)"
rm -f "$T/repo/.chump-locks/ambient.jsonl"
op_rc=0
(
    cd "$T/repo" &&     PATH="/usr/bin:/bin"     CHUMP_SESSION_ID="sess-repair"     CHUMP_TEST_GATE=0     CHUMP_CLIPPY_GATE=0     bash "$T/repo/scripts/git-hooks/pre-push" origin "$T/origin.git"         <<< "refs/heads/claude/infra-8595 $clean_sha refs/heads/claude/infra-8595 $base_sha"
) >"$T/out3" 2>&1 || op_rc=$?
amb="$(cat "$T/repo/.chump-locks/ambient.jsonl" 2>/dev/null || true)"
if [[ "$op_rc" -eq 0 ]] && grep -q '"kind":"test_gate_bypassed"' <<<"$amb" && ! grep -q 'prepush_lease_mismatch' <<<"$amb"; then
    ok "outside dispatch, operator CHUMP_TEST_GATE=0 passes AND repair lease branch claude/infra-8595 passes Guard 5 without trailer"
else
    fail "outside dispatch + repair lease failed: op_rc=$op_rc amb='$amb' out=$(cat "$T/out3")"
fi

# 5. Mutant check: drop dispatch no-bypass check in pre-push
python3 - "$T/repo/scripts/git-hooks/pre-push" "$T/repo/scripts/git-hooks/pre-push" <<'PY'
import sys
src = open(sys.argv[1]).read()
mut = src.replace(
    'if [[ -n "${CHUMP_DISPATCH_GAP:-}" || "${CHUMP_DISPATCH_DEPTH:-0}" -ge 1 ]]; then',
    'if false; then # MUTANT_DROPPED'
)
assert mut != src
open(sys.argv[1], "w").write(mut)
PY
chmod +x "$T/repo/scripts/git-hooks/pre-push"
mut_rc=0
(
    cd "$T/repo" &&     PATH="/usr/bin:/bin"     CHUMP_DISPATCH_GAP="INFRA-8597"     CHUMP_SESSION_ID="sess-repair"     CHUMP_TEST_GATE=0     CHUMP_CLIPPY_GATE=0     bash "$T/repo/scripts/git-hooks/pre-push" origin "$T/origin.git"         <<< "refs/heads/claude/infra-8595 $clean_sha refs/heads/claude/infra-8595 $base_sha"
) >/dev/null 2>&1 || mut_rc=$?
if [[ "$mut_rc" -eq 0 ]]; then
    ok "mutant (dropping dispatch bypass check) is killed (push would have succeeded)"
else
    fail "mutant did not change outcome (mut_rc=$mut_rc)"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
