#!/usr/bin/env bash
# scripts/ci/test-blame-bot.sh — INFRA-1989 (THE FLOOR Phase 1 finisher)
# CREDIBLE-080: extended with green→red→green and dedupe/stale tests
#
# Validates the green-to-red regression-attribution bot:
#   1. CHUMP_SKIP_BLAME_BOT=1 → silent no-op
#   2. No green baseline → emits regression_inattributable
#   3. Green baseline with NO commits since → emits regression_inattributable
#   4. Green baseline + commits touching mapped paths → emits regression_attributed
#      with suspect_commits CSV
#   5. --json output is parseable + has expected fields
#   6. --checks CSV limits attribution to those check names
#   7. (CREDIBLE-080 AC#4) Green→red→green fixture: expect blame_bot_self_resolved,
#      NOT regression_attributed
#   8. (CREDIBLE-080 AC#4) Green→red→partial-fix: unresolved checks still attributed
#   9. (CREDIBLE-080 AC#3) Dedupe: second run with same tuple → blame_bot_dedupe_skip
#  10. (CREDIBLE-080 AC#5) Stale baseline: >50 commits behind → blame_bot_baseline_stale
#
# Uses CHUMP_BLAME_BOT_TEST_GREEN_SHA + CHUMP_BLAME_BOT_TEST_REPO_ROOT to
# skip the live gh lookup and drive from a synthetic git history.
# Uses CHUMP_BLAME_BOT_TEST_CHECK_RUNS (JSON file path) for check-run injection.
#
# W-013 immunization (RESILIENT-024 pattern): unset workflow-injected env.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-1989 blame-bot tests (CREDIBLE-080 extended) ==="
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
COMMIT_B="$(git rev-parse HEAD)"

# Commit 3: change scripts/ci/ (likely cause for "audit")
echo "echo red" > scripts/ci/test-foo.sh
git add . && git commit -q -m "fix: tweak test-foo (#888)"
COMMIT_C="$(git rev-parse HEAD)"

# Commit 4: docs-only change (NOT a suspect for code checks)
mkdir -p docs
echo "doc" > docs/README.md
git add . && git commit -q -m "docs: update README"
COMMIT_D="$(git rev-parse HEAD)"

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
> "$FAKE/.chump-locks/ambient.jsonl"
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

# ── Test 7 (CREDIBLE-080 AC#4): green→red→green fixture ─────────────────────
# Commit A (GREEN_SHA): test passes
# Commit B: test breaks (red)
# Commit C: fix lands — test now green
# Expected: blame_bot_self_resolved emitted, NOT regression_attributed
echo "--- Test 7 (CREDIBLE-080 AC#4): green→red→green → blame_bot_self_resolved ---"
> "$FAKE/.chump-locks/ambient.jsonl"

# Build check-runs injection file:
# GREEN_SHA: test passes (not queried, it's the baseline)
# COMMIT_B: test fails
# COMMIT_C: test passes — this is the fix commit
# COMMIT_D: test passes
CHECK_RUNS_FILE="$TMP/check-runs-all-green.json"
python3 -c "
import json
data = {
    '$COMMIT_B': [{'name': 'test', 'conclusion': 'failure'}],
    '$COMMIT_C': [{'name': 'test', 'conclusion': 'success'}],
    '$COMMIT_D': [{'name': 'test', 'conclusion': 'success'}],
}
print(json.dumps(data))
" > "$CHECK_RUNS_FILE"

OUT=$(CHUMP_BLAME_BOT_TEST_GREEN_SHA="$GREEN_SHA" \
    CHUMP_BLAME_BOT_TEST_CHECK_RUNS="$CHECK_RUNS_FILE" \
    run_bot --checks test)

if grep -q "blame_bot_self_resolved" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "green→red→green: blame_bot_self_resolved fired"
else
    fail "green→red→green: expected blame_bot_self_resolved (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

if grep -q "regression_attributed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    fail "green→red→green: regression_attributed should NOT fire when all resolved"
else
    ok "green→red→green: regression_attributed correctly NOT emitted"
fi

# Verify resolving_commit is present in the event
if grep "blame_bot_self_resolved" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null \
   | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        evt = json.loads(line)
    except Exception:
        continue
    if evt.get('kind') == 'blame_bot_self_resolved':
        rc = evt.get('resolving_commit', '')
        ogsha = evt.get('original_green_sha', '')
        if rc and ogsha:
            print('OK')
            break
" 2>&1 | grep -q "OK"; then
    ok "blame_bot_self_resolved has resolving_commit + original_green_sha fields"
else
    fail "blame_bot_self_resolved missing required fields"
fi

# ── Test 8 (CREDIBLE-080 AC#4): green→red→partial fix ──────────────────────
# Two checks: 'test' gets resolved by COMMIT_C, 'audit' is NOT resolved.
# Expected: regression_attributed fires for 'audit', NOT self_resolved for all.
echo "--- Test 8 (CREDIBLE-080 AC#4): green→red→partial fix → attributed for unresolved check ---"
> "$FAKE/.chump-locks/ambient.jsonl"

# Only 'test' is resolved; 'audit' check never flips green
CHECK_RUNS_PARTIAL="$TMP/check-runs-partial.json"
python3 -c "
import json
data = {
    '$COMMIT_B': [
        {'name': 'test', 'conclusion': 'failure'},
        {'name': 'audit', 'conclusion': 'failure'},
    ],
    '$COMMIT_C': [
        {'name': 'test', 'conclusion': 'success'},
        {'name': 'audit', 'conclusion': 'failure'},
    ],
    '$COMMIT_D': [
        {'name': 'test', 'conclusion': 'success'},
        {'name': 'audit', 'conclusion': 'failure'},
    ],
}
print(json.dumps(data))
" > "$CHECK_RUNS_PARTIAL"

OUT=$(CHUMP_BLAME_BOT_TEST_GREEN_SHA="$GREEN_SHA" \
    CHUMP_BLAME_BOT_TEST_CHECK_RUNS="$CHECK_RUNS_PARTIAL" \
    run_bot --checks test,audit)

# Should NOT be fully self-resolved (audit still failing)
if grep -q "regression_attributed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "partial-fix: regression_attributed fired for unresolved check"
else
    fail "partial-fix: expected regression_attributed for unresolved audit check (out=$OUT, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

# ── Test 9 (CREDIBLE-080 AC#3): Dedupe — same tuple in last 30 min ──────────
echo "--- Test 9 (CREDIBLE-080 AC#3): second identical run → blame_bot_dedupe_skip ---"
> "$FAKE/.chump-locks/ambient.jsonl"

# Run first time — should emit regression_attributed
OUT1=$(CHUMP_BLAME_BOT_TEST_GREEN_SHA="$GREEN_SHA" run_bot --checks test,audit)
if grep -q "regression_attributed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "dedupe test: first run emitted regression_attributed"
else
    fail "dedupe test: first run should have emitted regression_attributed (out=$OUT1)"
fi

# Run second time with same tuple — should emit blame_bot_dedupe_skip, NOT another regression_attributed
AMBIENT_BEFORE="$(grep -c "regression_attributed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null || echo "0")"
OUT2=$(CHUMP_BLAME_BOT_TEST_GREEN_SHA="$GREEN_SHA" run_bot --checks test,audit)
AMBIENT_AFTER="$(grep -c "regression_attributed" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null || echo "0")"

if grep -q "blame_bot_dedupe_skip" "$FAKE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "dedupe test: blame_bot_dedupe_skip fired on second identical run"
else
    fail "dedupe test: expected blame_bot_dedupe_skip on second run (out=$OUT2, ambient=$(cat "$FAKE/.chump-locks/ambient.jsonl"))"
fi

if [[ "$AMBIENT_AFTER" -eq "$AMBIENT_BEFORE" ]]; then
    ok "dedupe test: regression_attributed NOT re-emitted on second run"
else
    fail "dedupe test: regression_attributed should not have been emitted again (before=$AMBIENT_BEFORE, after=$AMBIENT_AFTER)"
fi

# ── Test 10 (CREDIBLE-080 AC#5): Stale baseline — >50 commits behind ────────
echo "--- Test 10 (CREDIBLE-080 AC#5): green_sha >50 commits behind HEAD → blame_bot_baseline_stale ---"

# Build a repo with >50 commits after the green baseline
FAKE_STALE="$TMP/repo_stale"
mkdir -p "$FAKE_STALE/.chump-locks" "$FAKE_STALE/src"
cd "$FAKE_STALE" || exit 2
git init -q -b main
git config user.email t@t && git config user.name t

echo "fn ok() {}" > src/lib.rs
git add . && git commit -q -m "green baseline"
GREEN_SHA_STALE="$(git rev-parse HEAD)"

# Add 55 commits after the baseline to be clearly stale
for i in $(seq 1 55); do
    echo "// change $i" >> src/lib.rs
    git add . && git commit -q -m "chore: commit $i"
done

cd - >/dev/null

> "$FAKE_STALE/.chump-locks/ambient.jsonl"
OUT=$(CHUMP_BLAME_BOT_TEST_GREEN_SHA="$GREEN_SHA_STALE" \
    CHUMP_BLAME_BOT_TEST_REPO_ROOT="$FAKE_STALE" \
    CHUMP_AMBIENT_LOG="$FAKE_STALE/.chump-locks/ambient.jsonl" \
    CHUMP_BLAME_BOT_STALE_THRESHOLD="50" \
    bash "$BOT" --checks test 2>&1)

if grep -q "blame_bot_baseline_stale" "$FAKE_STALE/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "stale baseline: blame_bot_baseline_stale fired when >50 commits behind"
else
    fail "stale baseline: expected blame_bot_baseline_stale (out=$OUT, ambient=$(cat "$FAKE_STALE/.chump-locks/ambient.jsonl"))"
fi

if echo "$OUT" | grep -q "stale\|re-baseline"; then
    ok "stale baseline: human-readable stale warning printed"
else
    fail "stale baseline: expected stale warning in output (out=$OUT)"
fi

# Verify behind_commits field is present
if grep "blame_bot_baseline_stale" "$FAKE_STALE/.chump-locks/ambient.jsonl" 2>/dev/null \
   | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        evt = json.loads(line)
    except Exception:
        continue
    if evt.get('kind') == 'blame_bot_baseline_stale':
        if 'behind_commits' in evt and evt['behind_commits'] > 50:
            print('OK')
            break
" 2>&1 | grep -q "OK"; then
    ok "blame_bot_baseline_stale has behind_commits > 50"
else
    fail "blame_bot_baseline_stale missing behind_commits or value wrong"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
