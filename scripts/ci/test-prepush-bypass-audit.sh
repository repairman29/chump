#!/usr/bin/env bash
# CI: RESILIENT-014 — pre-push test-gate bypass audit trail
#
# Verifies that scripts/git-hooks/pre-push emits kind=test_gate_bypassed
# to ambient.jsonl when CHUMP_TEST_GATE=0 is used, with correct fields.
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HOOK="${REPO_ROOT}/scripts/git-hooks/pre-push"

# ── Set up a throwaway git repo with a commit containing a trailer ──────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_REPO="${TMPDIR_TEST}/repo"
git init "$FAKE_REPO" --quiet
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test"
git -C "$FAKE_REPO" checkout -b "chump/infra-999-claim" --quiet 2>/dev/null || \
  git -C "$FAKE_REPO" checkout -b "chump/infra-999-claim" 2>/dev/null || true

# Commit with Test-Gate-Bypass trailer
echo "test" > "$FAKE_REPO/file.txt"
git -C "$FAKE_REPO" add file.txt
git -C "$FAKE_REPO" commit -m "$(cat <<'EOF'
feat(INFRA-999): test commit

Test-Gate-Bypass: test infra broken on CI runner
EOF
)" --quiet

AMBIENT="${FAKE_REPO}/.chump-locks/ambient.jsonl"

# ── Test 1: CHUMP_TEST_GATE=0 emits test_gate_bypassed event ────────────────
echo "Test 1: CHUMP_TEST_GATE=0 emits ambient event"
CHUMP_TEST_GATE=0 CHUMP_GAP_CHECK=0 CHUMP_AUTOMERGE_OVERRIDE=1 \
  git -C "$FAKE_REPO" -c core.hooksPath="$TMPDIR_TEST/nohooks" \
  config core.hooksPath "$TMPDIR_TEST/nohooks" 2>/dev/null || true
mkdir -p "$TMPDIR_TEST/nohooks"

# Run only the TEST_GATE bypass section by sourcing the hook in a subshell
(
  cd "$FAKE_REPO"
  CHUMP_TEST_GATE=0 CHUMP_GAP_CHECK=0 CHUMP_AUTOMERGE_OVERRIDE=1 \
  CHUMP_FMT_CHECK=0 CHUMP_BUILD_CHECK=0 CHUMP_LEASE_CHECK=0 \
  HOME="$TMPDIR_TEST" \
    bash "$HOOK" origin "https://github.com/test/repo.git" <<< "" 2>/dev/null || true
)

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"test_gate_bypassed"' "$AMBIENT"; then
    ok "test_gate_bypassed event emitted on CHUMP_TEST_GATE=0"
else
    fail "test_gate_bypassed event NOT emitted (ambient: $(cat "$AMBIENT" 2>/dev/null || echo 'missing'))"
fi

# ── Test 2: bypass reason extracted from Test-Gate-Bypass trailer ────────────
echo "Test 2: reason extracted from Test-Gate-Bypass trailer"
if [[ -f "$AMBIENT" ]] && \
   grep '"kind":"test_gate_bypassed"' "$AMBIENT" | grep -q '"reason":"test infra broken on CI runner"'; then
    ok "reason extracted from Test-Gate-Bypass trailer"
else
    _got="$(grep '"kind":"test_gate_bypassed"' "$AMBIENT" 2>/dev/null | grep -o '"reason":"[^"]*"' || echo 'missing')"
    fail "reason not extracted correctly (got: $_got)"
fi

# ── Test 3: event NOT emitted when CHUMP_TEST_GATE is default (=1) ──────────
echo "Test 3: no event emitted when test gate runs normally"
AMBIENT2="${FAKE_REPO}2/.chump-locks/ambient.jsonl"
git init "$FAKE_REPO"2 --quiet 2>/dev/null || true
git -C "${FAKE_REPO}2" config user.email "test@test.com"
git -C "${FAKE_REPO}2" config user.name "Test"
echo "x" > "${FAKE_REPO}2/x.txt"
git -C "${FAKE_REPO}2" add x.txt
git -C "${FAKE_REPO}2" commit -m "normal commit" --quiet 2>/dev/null || true

(
  cd "${FAKE_REPO}2"
  CHUMP_GAP_CHECK=0 CHUMP_AUTOMERGE_OVERRIDE=1 \
  CHUMP_FMT_CHECK=0 CHUMP_BUILD_CHECK=0 CHUMP_LEASE_CHECK=0 \
  HOME="$TMPDIR_TEST" \
    bash "$HOOK" origin "https://github.com/test/repo.git" <<< "" 2>/dev/null || true
)

if [[ -f "$AMBIENT2" ]] && grep -q '"kind":"test_gate_bypassed"' "$AMBIENT2" 2>/dev/null; then
    fail "test_gate_bypassed emitted when CHUMP_TEST_GATE not set (should not emit)"
else
    ok "no test_gate_bypassed event when test gate runs normally"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
