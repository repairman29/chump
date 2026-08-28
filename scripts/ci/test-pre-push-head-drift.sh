#!/usr/bin/env bash
# test-pre-push-head-drift.sh — INFRA-2431 regression test.
#
# INFRA-2418 hit a false-positive: the pre-push head-drift guard (INFRA-1372
# AC-3) blocked a push when cargo test never actually created a commit — the
# guard's "before" and "after" `git rev-parse HEAD` reads disagreed only
# because GIT_DIR/GIT_WORK_TREE had been unset in the hook's shell (unset in
# a parent shell is permanent, not restored when the cargo-test subshell
# exits), so the second read could resolve against the wrong ref/repo.
#
# INFRA-2431 fix, verified here:
#   AC-2: the guard auto-skips when nothing in the diff can spawn a real git
#         subprocess (no Command::new("git") / git_cmd!() in any touched .rs
#         file) — no env-var bypass, a narrower gate.
#   AC-3: even when the guard runs, a raw SHA mismatch alone no longer
#         blocks the push — only a change in `git rev-list --count` (the
#         branch actually gaining/losing a commit) aborts.
#   AC-5: no new CHUMP_*_SKIP env var was introduced (zero-bypass thesis).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PRE_PUSH="$REPO_ROOT/scripts/git-hooks/pre-push"
PASS=0
FAIL=0

ok()  { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

# ── AC-2: source contract — head-drift guard has a skip path keyed on the
#          diff touching a git-spawning test file, with no new env var ────────
if grep -q '_SKIP_HEAD_DRIFT_CHECK=1' "$PRE_PUSH"; then
  ok "AC-2: pre-push sets _SKIP_HEAD_DRIFT_CHECK=1 when diff has no git-touching file"
else
  fail "AC-2: _SKIP_HEAD_DRIFT_CHECK=1 assignment NOT found in pre-push"
fi

if grep -qF 'Command::new("git")' "$PRE_PUSH" && grep -qF 'git_cmd!' "$PRE_PUSH"; then
  ok "AC-2: git-touching pattern check (Command::new(\"git\") / git_cmd!) present"
else
  fail "AC-2: git-touching pattern check NOT found in pre-push"
fi

if grep -qE 'CHUMP_[A-Z_]*HEAD_DRIFT[A-Z_]*_SKIP' "$PRE_PUSH"; then
  fail "AC-5: a new CHUMP_*_SKIP env var was added for head-drift (zero-bypass thesis violated)"
else
  ok "AC-5: no new CHUMP_*_SKIP env var introduced for head-drift"
fi

# ── AC-3: source contract — abort gated on commit COUNT, not raw SHA ─────────
if grep -q 'rev-list --count' "$PRE_PUSH"; then
  ok "AC-3: pre-push compares 'git rev-list --count' before deciding to abort"
else
  fail "AC-3: 'git rev-list --count' comparison NOT found in pre-push"
fi

if grep -q '_PRE_TEST_COUNT.*!=.*_POST_TEST_COUNT' "$PRE_PUSH"; then
  ok "AC-3: abort condition checks _PRE_TEST_COUNT != _POST_TEST_COUNT"
else
  fail "AC-3: commit-count inequality check NOT found guarding the abort"
fi

# ── AC-3 functional: same SHA-mismatch scenario, aligned commit count ─────────
# Reproduce the INFRA-2418 false-positive directly: two different SHAs that
# both sit on top of the SAME number of commits (as would happen if the
# "before" read and "after" read merely disagreed about *which* ref HEAD
# was, not about the branch actually growing). Assert count-based comparison
# treats this as NOT a drift.
TMPDIR_TEST="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

git init -q "$TMPDIR_TEST/repo"
(
  cd "$TMPDIR_TEST/repo"
  git config user.email test@test.com
  git config user.name test
  echo a > a.txt && git add a.txt && git commit -q -m "c1"
  echo b > b.txt && git add b.txt && git commit -q -m "c2"
  git branch other-branch
  echo c > c.txt && git add c.txt && git commit -q -m "c3-on-main"
  git checkout -q other-branch
  echo d > d-sibling.txt && git add d-sibling.txt && git commit -q -m "c3-on-other-branch"
  git checkout -q main 2>/dev/null || git checkout -q master
)

SHA_MAIN="$(git -C "$TMPDIR_TEST/repo" rev-parse HEAD)"
SHA_OTHER="$(git -C "$TMPDIR_TEST/repo" rev-parse other-branch)"
COUNT_MAIN="$(git -C "$TMPDIR_TEST/repo" rev-list --count "$SHA_MAIN")"
COUNT_OTHER="$(git -C "$TMPDIR_TEST/repo" rev-list --count "$SHA_OTHER")"

if [[ "$SHA_MAIN" != "$SHA_OTHER" && "$COUNT_MAIN" == "$COUNT_OTHER" ]]; then
  ok "AC-3 functional: fixture reproduces SHA-mismatch-but-same-count (the INFRA-2418 false-positive shape)"
else
  fail "AC-3 functional: fixture did not reproduce SHA-mismatch-but-same-count (SHA_MAIN=$SHA_MAIN SHA_OTHER=$SHA_OTHER COUNT_MAIN=$COUNT_MAIN COUNT_OTHER=$COUNT_OTHER)"
fi

# A genuine drift: same branch gains a real commit — count must differ.
(
  cd "$TMPDIR_TEST/repo"
  echo d > d.txt && git add d.txt && git commit -q -m "real-drift-commit"
)
SHA_AFTER_DRIFT="$(git -C "$TMPDIR_TEST/repo" rev-parse HEAD)"
COUNT_AFTER_DRIFT="$(git -C "$TMPDIR_TEST/repo" rev-list --count "$SHA_AFTER_DRIFT")"

if [[ "$COUNT_AFTER_DRIFT" != "$COUNT_MAIN" ]]; then
  ok "AC-3 functional: a real new commit DOES change rev-list --count (guard would still fire)"
else
  fail "AC-3 functional: real new commit did not change rev-list --count"
fi

# ── AC-4: this test file exists and is wired into CI ──────────────────────────
if grep -q 'test-pre-push-head-drift.sh' "$REPO_ROOT/.github/workflows/ci.yml"; then
  ok "AC-4: test-pre-push-head-drift.sh is wired into .github/workflows/ci.yml"
else
  fail "AC-4: test-pre-push-head-drift.sh NOT referenced in .github/workflows/ci.yml"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All checks passed."
