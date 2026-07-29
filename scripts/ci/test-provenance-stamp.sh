#!/usr/bin/env bash
# test-provenance-stamp.sh — CREDIBLE-172 / COTG-3.2
#
# Validates the commit-msg zero-touch provenance stamp:
#   1. With an active claim lease + no trailer -> the Chump-Agent trailer IS stamped.
#   2. With NO active claim (a human hand-commit) -> NOT stamped.
#   3. A message that already carries the trailer -> NOT double-stamped.
#   4. CHUMP_PROVENANCE_STAMP=0 -> disabled.
#   5. It never blocks: a missing .chump-locks dir still exits 0.
#
# Why: on 2026-07-29, 5 of 8 OS commits reached main WITHOUT the Chump-Agent
# trailer, so trailer-absence did not reliably mean "human" — the zero-touch /
# readiness metric was counting noise. The trailer is the only provenance signal
# that survives squash-merge (repo squash setting = COMMIT_MESSAGES).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/commit-msg"
PASS=0; FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== CREDIBLE-172 provenance-stamp test ==="
[ -f "$HOOK" ] || { echo "FAIL: $HOOK missing"; exit 1; }

# Hermetic scratch git repo so `git rev-parse --show-toplevel` resolves to it.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q
git config user.email t@t; git config user.name t
# Silence the docs-delta / bypass-trailer validators: the stamp runs before them
# and this repo has no chump binary + no staged docs, so they no-op. We invoke the
# hook directly with a message file (the exact contract: $1 = message path).

run_hook() { # <msgfile>  — run the commit-msg hook against a message file
    CHUMP_DOCS_DELTA_CHECK=0 bash "$HOOK" "$1" >/dev/null 2>&1
}

# 1. active claim + no trailer -> stamped
mkdir -p "$TMP/.chump-locks"
echo '{"session_id":"claim-credible-172-test","gap_id":"CREDIBLE-172"}' > "$TMP/.chump-locks/claim-test.json"
printf 'feat(CREDIBLE-172): a thing\n\nbody line\n' > "$TMP/m1.txt"
run_hook "$TMP/m1.txt"
if grep -qE '^Chump-Agent:' "$TMP/m1.txt"; then
    ok "active claim + no trailer -> Chump-Agent stamped"
else
    fail "active claim -> trailer NOT stamped (provenance leak persists)"
fi

# 2. no active claim (human hand-commit) -> NOT stamped
rm -f "$TMP/.chump-locks/"claim-*.json
printf 'human fixes a typo\n' > "$TMP/m2.txt"
run_hook "$TMP/m2.txt"
if grep -qE '^Chump-Agent:' "$TMP/m2.txt"; then
    fail "no claim -> stamped anyway (would mislabel a human commit as OS)"
else
    ok "no active claim -> left unstamped (human commit stays human)"
fi

# 3. already has the trailer -> not double-stamped
echo '{"session_id":"claim-x","gap_id":"CREDIBLE-172"}' > "$TMP/.chump-locks/claim-test.json"
printf 'feat: x\n\nChump-Agent: Zapp@rig7\n' > "$TMP/m3.txt"
run_hook "$TMP/m3.txt"
n=$(grep -cE '^Chump-Agent:' "$TMP/m3.txt")
if [ "$n" = "1" ]; then
    ok "pre-existing trailer -> not double-stamped (count=1)"
else
    fail "trailer count=$n (expected 1 — double-stamp or loss)"
fi

# 4. CHUMP_PROVENANCE_STAMP=0 -> disabled
printf 'feat: y\n' > "$TMP/m4.txt"
CHUMP_PROVENANCE_STAMP=0 CHUMP_DOCS_DELTA_CHECK=0 bash "$HOOK" "$TMP/m4.txt" >/dev/null 2>&1
if grep -qE '^Chump-Agent:' "$TMP/m4.txt"; then
    fail "bypass env ignored (still stamped)"
else
    ok "CHUMP_PROVENANCE_STAMP=0 -> stamp disabled"
fi

# 5. never blocks: no .chump-locks dir at all still exits 0
rm -rf "$TMP/.chump-locks"
printf 'feat: z\n' > "$TMP/m5.txt"
if CHUMP_DOCS_DELTA_CHECK=0 bash "$HOOK" "$TMP/m5.txt" >/dev/null 2>&1; then
    ok "no .chump-locks -> hook still exits 0 (fail-open, never blocks a commit)"
else
    fail "hook exited non-zero with no claim dir (would block commits)"
fi

# 6. THE REAL CASE: a linked worktree whose .chump-locks is empty, but the MAIN
#    checkout holds the lease. The stamp must resolve the lease via the common git
#    dir and fire — otherwise the fix is useless where fleet agents actually commit.
MAIN="$TMP/main"
git init -q "$MAIN"
git -C "$MAIN" config user.email t@t; git -C "$MAIN" config user.name t
git -C "$MAIN" commit -q --allow-empty -m seed
mkdir -p "$MAIN/.chump-locks"
echo '{"session_id":"claim-wt","gap_id":"CREDIBLE-172"}' > "$MAIN/.chump-locks/claim-wt.json"
git -C "$MAIN" worktree add -q "$TMP/wt" -b wtbranch >/dev/null 2>&1
# commit from INSIDE the worktree (its own .chump-locks is empty)
( cd "$TMP/wt" && printf 'feat(CREDIBLE-172): from a worktree\n' > msg.txt \
  && CHUMP_DOCS_DELTA_CHECK=0 bash "$HOOK" msg.txt >/dev/null 2>&1 \
  && grep -qE '^Chump-Agent:' msg.txt ) \
  && ok "worktree commit + lease in MAIN checkout -> stamped (via common git dir)" \
  || fail "worktree commit NOT stamped — the fix would miss the real fleet case"

echo "=== provenance-stamp: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
