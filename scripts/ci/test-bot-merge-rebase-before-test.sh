#!/usr/bin/env bash
# test-bot-merge-rebase-before-test.sh — INFRA-918 smoke test
#
# Verifies:
#   1. bot_merge_rebase_before_test scanner-anchor present in bot-merge.sh
#   2. bot_merge_test_failure scanner-anchor present in bot-merge.sh
#   3. Both events registered in EVENT_REGISTRY.yaml
#   4. failure_class field emitted for transient_oom vs permanent_failure
#   5. bot_merge_rebase_before_test emitted in a dry-run bot-merge invocation
#   6. bot_merge_phase_duration covers cargo test phase (stage_start label check)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$BOT_MERGE" ]] || fail "bot-merge.sh not found at $BOT_MERGE"

# ── Test 1: scanner-anchor for bot_merge_rebase_before_test ─────────────────
if grep -q '"kind":"bot_merge_rebase_before_test"' "$BOT_MERGE"; then
    pass "Test 1: bot_merge_rebase_before_test scanner-anchor found in bot-merge.sh"
else
    fail "Test 1: missing scanner-anchor 'kind':'bot_merge_rebase_before_test' in bot-merge.sh"
fi

# ── Test 2: scanner-anchor for bot_merge_test_failure ───────────────────────
if grep -q '"kind":"bot_merge_test_failure"' "$BOT_MERGE"; then
    pass "Test 2: bot_merge_test_failure scanner-anchor found in bot-merge.sh"
else
    fail "Test 2: missing scanner-anchor 'kind':'bot_merge_test_failure' in bot-merge.sh"
fi

# ── Test 3: both events registered in EVENT_REGISTRY.yaml ───────────────────
[[ -f "$EVENT_REG" ]] || fail "Test 3: EVENT_REGISTRY.yaml not found at $EVENT_REG"
if grep -q "bot_merge_rebase_before_test" "$EVENT_REG"; then
    pass "Test 3a: bot_merge_rebase_before_test registered in EVENT_REGISTRY.yaml"
else
    fail "Test 3a: bot_merge_rebase_before_test not found in $EVENT_REG"
fi
if grep -q "bot_merge_test_failure" "$EVENT_REG"; then
    pass "Test 3b: bot_merge_test_failure registered in EVENT_REGISTRY.yaml"
else
    fail "Test 3b: bot_merge_test_failure not found in $EVENT_REG"
fi

# ── Test 4: failure_class OOM detection logic present ───────────────────────
if grep -q "transient_oom" "$BOT_MERGE" && grep -q "permanent_failure" "$BOT_MERGE"; then
    pass "Test 4: failure_class values (transient_oom, permanent_failure) present in bot-merge.sh"
else
    fail "Test 4: missing failure_class classification logic in bot-merge.sh"
fi

# ── Test 5: bot_merge_rebase_before_test emitted in dry-run ─────────────────
TMP="$(mktemp -d -t test-bm-rebase-before-test.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

AMBIENT="$TMP/ambient.jsonl"
FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/.chump-locks" "$FAKE_REPO/.chump"

sqlite3 "$FAKE_REPO/.chump/state.db" "
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT,
    priority TEXT, effort TEXT, depends_on TEXT, acceptance_criteria TEXT,
    description TEXT, closed_pr INTEGER, tags TEXT
);
INSERT OR IGNORE INTO gaps (id,domain,title,status,priority,effort)
    VALUES ('TEST-918','TEST','rebase-before-test smoke','open','P2','xs');
" 2>/dev/null || touch "$FAKE_REPO/.chump/state.db"

MOCK_GH="$TMP/gh"
cat > "$MOCK_GH" <<'GHEOF'
#!/usr/bin/env bash
subcmd="${1:-}"; shift || true
case "$subcmd" in
  auth)   exit 0 ;;
  pr)
    pr_cmd="${1:-}"; shift || true
    case "$pr_cmd" in
      view)   printf '{"number":42,"state":"OPEN","autoMergeRequest":null}\n' ;;
      list)   echo '[]' ;;
      create) printf 'https://github.com/test/repo/pull/42\n'; exit 0 ;;
      *)      exit 0 ;;
    esac ;;
  api)
    case "${1:-}" in
      rate_limit) printf '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":1747200000},"graphql":{"limit":5000,"remaining":4900,"reset":1747200060}}}\n' ;;
      *)          echo '[]' ;;
    esac ;;
  *)      exit 0 ;;
esac
GHEOF
chmod +x "$MOCK_GH"

MOCK_GIT="$TMP/git"
cat > "$MOCK_GIT" <<'GITEOF'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  rev-parse)
    case "${1:-}" in
      --show-toplevel)  printf '%s\n' "$FAKE_REPO" ;;
      --git-common-dir) printf '%s/.git\n' "$FAKE_REPO" ;;
      HEAD)             printf 'abc1234567890abcdef1234567890abcdef123456\n' ;;
      --quiet)          exit 0 ;;
      *)                printf 'abc1234567890abcdef1234567890abcdef123456\n' ;;
    esac ;;
  remote)    printf 'https://github.com/testorg/testrepo.git\n' ;;
  rev-list)  printf '0\n' ;;
  log)       exit 0 ;;
  status)    exit 0 ;;
  push)      exit 0 ;;
  fetch)     exit 0 ;;
  diff)      exit 0 ;;
  symbolic-ref) printf 'chump/test-918-smoke\n' ;;
  *)         exit 0 ;;
esac
GITEOF
chmod +x "$MOCK_GIT"

MOCK_CHUMP="$TMP/chump"
cat > "$MOCK_CHUMP" <<'CHEOF'
#!/usr/bin/env bash
subcmd="${1:-}"; shift || true
case "$subcmd" in
  gap)
    gap_cmd="${1:-}"; shift || true
    case "$gap_cmd" in
      preflight) exit 0 ;;
      ship)      exit 0 ;;
      list)      echo '[]' ;;
      show)      echo 'status: open' ;;
      *)         exit 0 ;;
    esac ;;
  fleet) exit 0 ;;
  *)     exit 0 ;;
esac
CHEOF
chmod +x "$MOCK_CHUMP"

export PATH="$TMP:$PATH"
export FAKE_REPO
export CHUMP_AMBIENT_LOG="$AMBIENT"
export CHUMP_STATE_DB="$FAKE_REPO/.chump/state.db"

cd "$FAKE_REPO"
CHUMP_TEST_GATE=0 CHUMP_BYPASS_BOT_MERGE=1 CHUMP_GAP_CHECK=0 \
CHUMP_PRE_MERGE_CHECKPOINT=0 CHUMP_SPEC_ON_SPEC_CHECK=0 \
CHUMP_SPECULATIVE_SWEEP=0 CHUMP_CODEREVIEW=0 CHUMP_AUTO_CLOSE_GAP=0 \
CHUMP_GAP_PREFLIGHT_SKIP=1 MAIN_REPO="$FAKE_REPO" \
bash "$BOT_MERGE" --gap TEST-918 --auto-merge --dry-run 2>/dev/null || true

if [[ -f "$AMBIENT" ]] && grep -q '"kind":"bot_merge_rebase_before_test"' "$AMBIENT"; then
    pass "Test 5: bot_merge_rebase_before_test emitted to ambient in dry-run"
else
    fail "Test 5: bot_merge_rebase_before_test not found in ambient after dry-run"
fi

# ── Test 6: stage_start label matches AC#3 phase name ───────────────────────
# AC#3: test cost tracked via bot_merge_phase_duration with phase="cargo test --bin chump --tests"
if grep -q 'stage_start "cargo test --bin chump --tests"' "$BOT_MERGE"; then
    pass "Test 6: stage_start label matches AC#3 phase name for bot_merge_phase_duration"
else
    fail "Test 6: stage_start label 'cargo test --bin chump --tests' not found in bot-merge.sh"
fi

echo ""
echo "All INFRA-918 rebase-before-test checks passed (6/6)."
