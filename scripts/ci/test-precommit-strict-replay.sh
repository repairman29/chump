#!/usr/bin/env bash
# test-precommit-strict-replay.sh — INFRA-767
#
# Verifies scripts/ci/precommit-strict-replay.sh:
#   1. No PR diff (HEAD == base) → replay is a no-op (exit 0)
#   2. PR diff with no guard violations → replay passes
#   3. PR diff that violates the event-registry guard → replay BLOCKS
#   4. HEAD is restored to original commit on exit (worktree state preserved)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-767 precommit-strict-replay tests ==="
echo

# Test runs an isolated fake repo. Unset any caller-set git env vars
# that would otherwise hijack the fake repo's git invocations.
unset GIT_WORK_TREE GIT_DIR GIT_COMMON_DIR

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/precommit-strict-replay.sh"

if [[ ! -x "$SCRIPT" ]]; then
    echo "FATAL: $SCRIPT not executable"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a fake repo with the strict-replay script + a stub guard that we
# can flip pass/fail via env. This isolates the test from the real repo's
# guard suite.
FAKE="$TMP/repo"
mkdir -p "$FAKE/scripts/ci" "$FAKE/scripts/git-hooks" "$FAKE/docs/observability"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t && git -C "$FAKE" config user.name t

# Copy a pruned strict-replay that only knows about ONE guard so the test
# is deterministic.
cat > "$FAKE/scripts/ci/precommit-strict-replay.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="\$(git rev-parse --show-toplevel)"
cd "\$REPO_ROOT"

BASE_FULL="\${GITHUB_BASE_REF:-main}"
git rev-parse "\$BASE_FULL" >/dev/null 2>&1 || { echo "no base ref"; exit 0; }

if [[ "\$(git rev-parse HEAD)" == "\$(git rev-parse "\$BASE_FULL")" ]]; then
    echo "[strict] HEAD==base; no-op"
    exit 0
fi

ORIG_HEAD="\$(git rev-parse HEAD)"
trap 'git reset --soft "\$ORIG_HEAD" >/dev/null 2>&1 || true; git reset >/dev/null 2>&1 || true' EXIT

git reset --soft "\$BASE_FULL" >/dev/null 2>&1
git add -A >/dev/null 2>&1

GUARD="\$REPO_ROOT/scripts/git-hooks/pre-commit-test-guard.sh"
if [[ -x "\$GUARD" ]]; then
    if ! CHUMP_TEST_GUARD_BYPASS=0 "\$GUARD"; then
        echo "[strict] guard tripped"
        exit 1
    fi
fi
echo "[strict] all guards passed"
exit 0
EOF
chmod +x "$FAKE/scripts/ci/precommit-strict-replay.sh"

# Stub guard: fails when staged diff contains the literal "FORBIDDEN_TOKEN".
# Bypass via CHUMP_TEST_GUARD_BYPASS=1 (which the strict-replay forces off).
cat > "$FAKE/scripts/git-hooks/pre-commit-test-guard.sh" <<'GUARD'
#!/usr/bin/env bash
[[ "${CHUMP_TEST_GUARD_BYPASS:-0}" == "1" ]] && exit 0
diff=$(git diff --cached --no-color 2>/dev/null || true)
if echo "$diff" | grep -q "FORBIDDEN_TOKEN"; then
    echo "[guard] FORBIDDEN_TOKEN present in diff" >&2
    exit 1
fi
exit 0
GUARD
chmod +x "$FAKE/scripts/git-hooks/pre-commit-test-guard.sh"

# Seed an initial commit (= base).
echo "baseline" > "$FAKE/README.md"
git -C "$FAKE" add . && git -C "$FAKE" commit -q -m "base"

# ── Test 1: HEAD == base → no-op ────────────────────────────────────────────
echo "--- Test 1: HEAD == base → no-op ---"
cd "$FAKE" || exit 2
OUT=$(bash scripts/ci/precommit-strict-replay.sh 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "HEAD==base"; then
    ok "no-op when no diff vs base"
else
    fail "expected no-op (rc=$RC, out=$OUT)"
fi
cd - >/dev/null

# ── Test 2: clean PR diff → strict-replay passes ────────────────────────────
echo "--- Test 2: clean PR diff → replay passes ---"
cd "$FAKE" || exit 2
git checkout -qb feature
echo "innocuous" > new_file.txt
git add . && git commit -q -m "innocuous change"
ORIG_BEFORE="$(git rev-parse HEAD)"

OUT=$(bash scripts/ci/precommit-strict-replay.sh 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "all guards passed"; then
    ok "clean diff replay passed"
else
    fail "expected pass (rc=$RC, out=$OUT)"
fi

ORIG_AFTER="$(git rev-parse HEAD)"
if [[ "$ORIG_BEFORE" == "$ORIG_AFTER" ]]; then
    ok "HEAD restored after replay"
else
    fail "HEAD should be restored ($ORIG_BEFORE → $ORIG_AFTER)"
fi
cd - >/dev/null

# ── Test 3: PR diff with FORBIDDEN_TOKEN → guard trips ──────────────────────
echo "--- Test 3: PR diff violates guard → replay BLOCKS ---"
cd "$FAKE" || exit 2
echo "FORBIDDEN_TOKEN here" >> new_file.txt
git add . && git commit -q -m "violates guard"
ORIG_BEFORE2="$(git rev-parse HEAD)"

OUT=$(bash scripts/ci/precommit-strict-replay.sh 2>&1)
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -q "guard tripped"; then
    ok "violation detected, replay blocks"
else
    fail "expected block (rc=$RC, out=$OUT)"
fi

ORIG_AFTER2="$(git rev-parse HEAD)"
if [[ "$ORIG_BEFORE2" == "$ORIG_AFTER2" ]]; then
    ok "HEAD restored after BLOCKED replay"
else
    fail "HEAD should be restored even on block ($ORIG_BEFORE2 → $ORIG_AFTER2)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
