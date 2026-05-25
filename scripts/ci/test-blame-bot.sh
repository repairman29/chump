#!/usr/bin/env bash
# scripts/ci/test-blame-bot.sh — INFRA-1989 (THE FLOOR Phase 1 finisher)
#
# Validates the green-to-red regression-attribution bot:
#   1. CHUMP_SKIP_BLAME_BOT=1 → silent no-op
#   2. No green baseline → emits regression_inattributable
#   3. Green baseline with NO commits since → emits regression_inattributable
#   4. Green baseline + commits touching mapped paths → emits regression_attributed
#      with suspect_commits CSV
#   5. --json output is parseable + has expected fields
#   6. --checks CSV limits attribution to those check names
#
# Uses CHUMP_BLAME_BOT_TEST_GREEN_SHA + CHUMP_BLAME_BOT_TEST_REPO_ROOT to
# skip the live gh lookup and drive from a synthetic git history.
#
# W-013 immunization (RESILIENT-024 pattern): unset workflow-injected env.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1989 blame-bot tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BOT="$REPO_ROOT/scripts/coord/blame-bot.sh"

if [[ ! -x "$BOT" ]]; then
    echo "FATAL: blame-bot not executable: $BOT"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# W-013 immunization
unset CHUMP_REPO CHUMP_LOCK_DIR

# Build a synthetic git repo with green→red lineage
FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks" "$FAKE/src" "$FAKE/scripts/ci"
cd "$FAKE" || exit 2
git init -q -b main
git config user.email t@t && git config user.name t

# Commit 1: green baseline
echo "fn ok() {}" > src/lib.rs
mkdir -p scripts/ci
echo "echo green" > scripts/ci/test-foo.sh
git add . && git commit -q -m "green baseline"
GREEN_SHA="$(git rev-parse HEAD)"

# Commit 2: change src/ (likely cause for "test" check)
echo "fn bad() {}" >> src/lib.rs
git add . && git commit -q -m "feat: add bad() — #999"

# Commit 3: change scripts/ci/ (likely cause for "audit")
echo "echo red" > scripts/ci/test-foo.sh
git add . && git commit -q -m "fix: tweak test-foo (#888)"

# Commit 4: docs-only change (NOT a suspect for code checks)
mkdir -p docs
echo "doc" > docs/README.md
git add . && git commit -q -m "docs: update README"

cd - >/dev/null

# Helper to invoke the bot against the fake repo
run_bot() {
    CHUMP_BLAME_BOT_TEST_REPO_ROOT="$FAKE" \
    CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    bash "$BOT" "$@" 2>&1
}

# ── Test 1: bypass env ──────────────────────────────────────────────────────
echo "--- Test 1: CHUMP_SKIP_BLAME_BOT=1 → silent no-op ---"
OUT=$(CHUMP_SKIP_BLAME_BOT=1 run_bot)
if echo "$OUT" | grep -q "skipped"; then
    ok "bypass env produced skip message"
else
    fail "bypass should print skip (out=$OUT)"
fi

# ── Test 2: no green baseline → inattributable ──────────────────────────────
echo "--- Test 2: no green baseline → kind=regression_inattributable ---"
> "$FAKE/.chump-locks/ambient.jsonl"
# Use a fake green_sha that doesn't exist → falls through to inattributable
# Actually, the bot uses git log green..HEAD; if green doesn't exist git errors.
# So pass empty as green to trigger the "no_green_baseline" path.
CHUMP_BLAME_BOT_TEST_GREEN_SHA="" \
    CHUMP_BLAME_BOT_TEST_REPO_ROOT="$FAKE" \
    CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    bash "$BOT" 2>&1 | head -3 >/dev/null
# Need to force no green discovery — set CHUMP_BLAME_BOT_TEST_GREEN_SHA="NONE"?
# Simpler: don't set test green, gh isn't real, fallback HEAD~5 also fails on
# a 4-commit repo, so it returns "" → no_green_baseline branch.
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(env -u CHUMP_BLAME_BOT_TEST_GREEN_SHA \
    PATH="/usr/bin:/bin" \
    CHUMP_BLAME_BOT_TEST_REPO_ROOT="$FAKE" \
    CHUMP_AMBIENT_LOG="$FAKE/.chump-locks/ambient.jsonl" \
    bash "$BOT" 2>&1)
if grep -q "regression_inattributable\|no_green_baseline" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   || echo "$OUT" | grep -q "cannot find a green baseline\|no commits in"; then
    ok "no green baseline produced inattributable signal"
else
    fail "expected inattributable (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 3: green=HEAD → no commits since → inattributable ──────────────────
echo "--- Test 3: green=HEAD (no commits since) → inattributable ---"
> "$FAKE/.chump-locks/ambient.jsonl"
CURRENT_HEAD="$(git -C "$FAKE" rev-parse HEAD)"
OUT=$(CHUMP_BLAME_BOT_TEST_GREEN_SHA="$CURRENT_HEAD" run_bot)
if grep -q "regression_inattributable" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   || echo "$OUT" | grep -q "no commits in"; then
    ok "green=HEAD produced inattributable (no diff window)"
else
    fail "expected inattributable for empty diff (out=$OUT)"
fi

# ── Test 4: green baseline + commits → attributed ───────────────────────────
echo "--- Test 4: green baseline + src/ commits → kind=regression_attributed ---"
> "$FAKE/.chump-locks/ambient.jsonl"
OUT=$(CHUMP_BLAME_BOT_TEST_GREEN_SHA="$GREEN_SHA" run_bot --checks test,audit)
if grep -q "regression_attributed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q "suspect_commits" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "regression_attributed event fired with suspect_commits"
else
    fail "expected attributed event (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

if echo "$OUT" | grep -qE '#[0-9]+'; then
    ok "human output references PR number(s)"
else
    fail "expected PR references in output (out=$OUT)"
fi

# ── Test 5: --json output parseable ─────────────────────────────────────────
echo "--- Test 5: --json output is parseable JSON with expected fields ---"
OUT=$(CHUMP_BLAME_BOT_TEST_GREEN_SHA="$GREEN_SHA" run_bot --checks test --json)
if echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('status') == 'attributed', f'status={d.get(\"status\")}'
assert 'green_sha' in d
assert 'suspect_commits' in d
assert isinstance(d['suspect_commits'], list)
assert d.get('count', 0) >= 1
print('OK')
" 2>&1 | grep -q "OK"; then
    ok "--json output has expected shape"
else
    fail "--json output malformed (out=$OUT)"
fi

# ── Test 6: --checks CSV limits attribution ────────────────────────────────
echo "--- Test 6: --checks pre-push limits attribution to git-hooks paths ---"
> "$FAKE/.chump-locks/ambient.jsonl"
# pre-push maps to scripts/git-hooks/ only; our fake has no such file → no suspects
OUT=$(CHUMP_BLAME_BOT_TEST_GREEN_SHA="$GREEN_SHA" run_bot --checks pre-push)
if grep -q "regression_inattributable" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   || echo "$OUT" | grep -q "no commits in"; then
    ok "--checks pre-push correctly found no hook commits (path filter works)"
else
    fail "expected inattributable for pre-push with no hook changes (out=$OUT)"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
