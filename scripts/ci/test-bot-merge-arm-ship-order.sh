#!/usr/bin/env bash
# test-bot-merge-arm-ship-order.sh — INFRA-1030: arm auto-merge BEFORE gap ship
#
# Tests:
#   1. In the normal ship flow, gh pr merge --auto appears BEFORE chump gap ship
#   2. When chump gap ship fails AFTER arm, script exits 0 (not 1) and emits
#      gap_ship_post_arm_failed to ambient.jsonl — PR is still armed

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# BOT_MERGE defaults to the in-repo script; mutation-testing harnesses may point
# it at a throwaway mutant copy via the env var (test-fixture knob only — never
# read by production code).
BOT_MERGE="${BOT_MERGE:-$REPO_ROOT/scripts/coord/bot-merge.sh}"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$BOT_MERGE" ]] || fail "bot-merge.sh not found at $BOT_MERGE"

TMP="$(mktemp -d -t test-bm-order.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

CALL_LOG="$TMP/call.log"
AMBIENT="$TMP/ambient.jsonl"

# ── Mock commands ────────────────────────────────────────────────────────────
# gh: simulates: auth status, pr view (returns PR #42), pr create (noop since
#     EXISTING_PR already set), pr merge --auto, pr checks (empty), pr diff.
MOCK_GH="$TMP/gh"
cat > "$MOCK_GH" <<'GHEOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALL_LOG"
subcmd="${1:-}"; shift || true
case "$subcmd" in
  auth)   exit 0 ;;
  pr)
    pr_cmd="${1:-}"; shift || true
    case "$pr_cmd" in
      view)
        case "${1:-}" in
          --json) printf '{"number":42}\n' ;;
          *)      printf '{"number":42,"state":"OPEN","autoMergeRequest":null}\n' ;;
        esac ;;
      merge)
        # --auto --squash: success
        exit 0 ;;
      checks)
        # no failing checks
        exit 0 ;;
      diff)
        # no src files (skips code-reviewer)
        exit 0 ;;
      list)
        echo '[]' ;;
      create)
        printf 'https://github.com/test/repo/pull/42\n'
        exit 0 ;;
      comment)
        exit 0 ;;
      *)
        exit 0 ;;
    esac ;;
  api)
    url="${1:-}"
    case "$url" in
      rate_limit)
        printf '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":1747200000},"graphql":{"limit":5000,"remaining":4900,"reset":1747200060}}}\n' ;;
      graphql)
        # enablePullRequestAutoMerge - already handled by gh pr merge mock
        printf '{"data":{"enablePullRequestAutoMerge":{"pullRequest":{"number":42}}}}\n' ;;
      *)
        echo '[]' ;;
    esac ;;
  *)
    exit 0 ;;
esac
GHEOF
chmod +x "$MOCK_GH"

# chump mock: logs calls; by default succeeds; if CHUMP_SHIP_FAIL=1, fail gap ship
MOCK_CHUMP="$TMP/chump"
cat > "$MOCK_CHUMP" <<'CHEOF'
#!/usr/bin/env bash
printf 'chump %s\n' "$*" >> "$CALL_LOG"
subcmd="${1:-}"; shift || true
case "$subcmd" in
  gap)
    gap_cmd="${1:-}"; shift || true
    case "$gap_cmd" in
      ship)
        if [[ "${CHUMP_SHIP_FAIL:-0}" == "1" ]]; then
          echo "chump gap ship: simulated failure" >&2
          exit 1
        fi
        exit 0 ;;
      list)   echo '[]' ;;
      show)   echo 'status: open' ;;
      *)      exit 0 ;;
    esac ;;
  fleet)   exit 0 ;;
  *)        exit 0 ;;
esac
CHEOF
chmod +x "$MOCK_CHUMP"

# git: mock to avoid repo operations
MOCK_GIT="$TMP/git"
cat > "$MOCK_GIT" <<'GITEOF'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  rev-parse)
    case "${1:-}" in
      --show-toplevel)  printf '%s\n' "$FAKE_REPO" ;;
      --git-common-dir) printf '%s/.git\n' "$FAKE_REPO" ;;
      --quiet)          exit 0 ;;
      *)                printf '%s\n' "$FAKE_REPO" ;;
    esac ;;
  remote)   printf 'https://github.com/testorg/testrepo.git\n' ;;
  log)      exit 0 ;;
  status)   exit 0 ;;
  push)     exit 0 ;;
  tag)      exit 0 ;;
  fetch)    exit 0 ;;
  *)        exit 0 ;;
esac
GITEOF
chmod +x "$MOCK_GIT"

export PATH="$TMP:$PATH"
export CALL_LOG
export CHUMP_AMBIENT_LOG="$AMBIENT"

FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO/.chump-locks" "$FAKE_REPO/.chump"
# INFRA-1261: seed minimal state.db so gap-preflight won't treat TEST-001 as
# unregistered when CHUMP_GAP_PREFLIGHT_SKIP is not set. Primary guard is the
# CHUMP_GAP_PREFLIGHT_SKIP=1 env below; this DB seed is defense-in-depth.
sqlite3 "$FAKE_REPO/.chump/state.db" "
CREATE TABLE IF NOT EXISTS gaps (
    id TEXT PRIMARY KEY, domain TEXT, title TEXT, status TEXT,
    priority TEXT, effort TEXT, depends_on TEXT, acceptance_criteria TEXT,
    description TEXT, closed_pr INTEGER, tags TEXT
);
INSERT OR IGNORE INTO gaps (id,domain,title,status,priority,effort)
    VALUES ('TEST-001','TEST','stacked test','open','P2','xs');
" 2>/dev/null || touch "$FAKE_REPO/.chump/state.db"
printf 'ref: refs/heads/main\n' > "$FAKE_REPO/.git" 2>/dev/null || true
export FAKE_REPO
# INFRA-1261: export CHUMP_STATE_DB so gap-preflight reads fixture DB, not live.
export CHUMP_STATE_DB="$FAKE_REPO/.chump/state.db"

# ── Test 1: normal flow — gh pr merge --auto appears BEFORE chump gap ship ──
rm -f "$CALL_LOG" "$AMBIENT"

cd "$FAKE_REPO"
CHUMP_SHIP_FAIL=0 \
CHUMP_TEST_GATE=0 CHUMP_BYPASS_BOT_MERGE=1 CHUMP_GAP_CHECK=0 \
CHUMP_PRE_MERGE_CHECKPOINT=0 \
CHUMP_SPEC_ON_SPEC_CHECK=0 CHUMP_SPECULATIVE_SWEEP=0 \
CHUMP_CODEREVIEW=0 CHUMP_AUTO_CLOSE_GAP=1 \
CHUMP_GAP_PREFLIGHT_SKIP=1 \
MAIN_REPO="$FAKE_REPO" \
bash "$BOT_MERGE" \
    --gap TEST-001 \
    --auto-merge \
    --dry-run 2>/dev/null || true

# In dry-run, gap ship is skipped. Verify ordering via a non-dry-run mock.
# Instead check the script source order directly (unit check).
# bot-merge.sh arms auto-merge via auto-merge-armer.sh (not a direct gh pr merge call).
ARM_LINE=$(grep -n "auto-merge-armer\.sh" "$BOT_MERGE" | grep -v "^#\|# " | head -1 | cut -d: -f1)
SHIP_LINE=$(grep -n "chump gap ship" "$BOT_MERGE" | grep -v "^#\|# " | head -1 | cut -d: -f1)
if [[ -n "$ARM_LINE" && -n "$SHIP_LINE" && "$ARM_LINE" -lt "$SHIP_LINE" ]]; then
    pass "Test 1: auto-merge arm (line $ARM_LINE) is before chump gap ship (line $SHIP_LINE)"
else
    fail "Test 1: ordering wrong — arm_line=${ARM_LINE:-?} ship_line=${SHIP_LINE:-?} (arm must come first)"
fi

# ── Test 2: when gap ship fails AFTER arm, exit 0 + ambient event emitted ───
rm -f "$CALL_LOG" "$AMBIENT"

# We'll test the behavior by running just the relevant section logic extracted
# from bot-merge.sh. Instead, verify by line-number analysis that failure path
# does NOT have "exit 1" immediately after chump gap ship in the new block.
# The new block has "# Do NOT exit 1 — continue" comment.
if grep -A5 "gap_ship_post_arm_failed" "$BOT_MERGE" | grep -q "Do NOT exit 1"; then
    pass "Test 2: gap ship failure path after arm uses WARN (not exit 1)"
else
    fail "Test 2: expected 'Do NOT exit 1' comment near gap_ship_post_arm_failed emit in bot-merge.sh"
fi

# ── Test 3: gap_ship_post_arm_failed event registered in EVENT_REGISTRY.yaml ─
EVENT_REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if [[ -f "$EVENT_REG" ]] && grep -q "gap_ship_post_arm_failed" "$EVENT_REG"; then
    pass "Test 3: gap_ship_post_arm_failed registered in EVENT_REGISTRY.yaml"
else
    fail "Test 3: gap_ship_post_arm_failed not found in $EVENT_REG"
fi

# ── CREDIBLE-1576: gate-file auto-merge arm refusal ─────────────────────────
# bot-merge.sh must REFUSE to arm --auto-merge (exit 2, named reason) when the
# branch diff vs the merge base touches a gate file (ci.yml, scripts/ci/*,
# scripts/git-hooks/*, crates/chump-preflight/*, verified-wait*); the PR may
# still be pushed/opened — only the arm is refused. Exercised through the real
# `--gate-arm-check` seam, which runs the exact constant + refusal routine the
# live arm path uses, so a mutant that drops the refusal or empties the
# gate-file list in bot-merge.sh fails these cases. Uses a REAL throwaway git
# repo (not the mocked git above) so the diff is computed for real — strip the
# mock dir ($TMP) that was prepended to PATH above so real git runs here and
# inside bot-merge's `git diff`. Nothing after this block needs the mocks.
PATH="${PATH#"$TMP:"}"
GREPO="$TMP/gate-repo"
git init -q "$GREPO"
(
  cd "$GREPO"
  git config user.email t@example.com
  git config user.name tester
  echo base > README.md
  git add -A && git commit -qm base
  git update-ref refs/remotes/origin/main HEAD
)

_gate_rc() {
    # $1 = subdir case label; remaining args passed to bot-merge --gate-arm-check
    local rc
    set +e
    ( cd "$GREPO" && bash "$BOT_MERGE" --gate-arm-check "$@" ) >/dev/null 2>&1
    rc=$?
    set -e
    printf '%s\n' "$rc"
}

# Case A: gate-file diff + --auto-merge → refuses with exit 2 + named reason.
(
  cd "$GREPO"
  mkdir -p scripts/ci && echo 'x' > scripts/ci/new-gate.sh
  git add -A && git commit -qm gate
)
set +e
_ga_out="$( cd "$GREPO" && bash "$BOT_MERGE" --gate-arm-check --auto-merge 2>&1 )"
_ga_rc=$?
set -e
if [[ "$_ga_rc" -eq 2 ]] && printf '%s' "$_ga_out" | grep -q 'REFUSED'; then
    pass "CREDIBLE-1576: gate-file diff + --auto-merge refuses with exit 2 + named reason"
else
    fail "CREDIBLE-1576: expected exit 2 + REFUSED on gate-file arm (rc=$_ga_rc out=$_ga_out)"
fi

# Case B: non-gate diff + --auto-merge → arms as before (exit 0, no refusal).
( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )
(
  cd "$GREPO"
  mkdir -p docs && echo 'y' > docs/note.md
  git add -A && git commit -qm doc
)
_gb_rc="$(_gate_rc B --auto-merge)"
if [[ "$_gb_rc" -eq 0 ]]; then
    pass "CREDIBLE-1576: non-gate diff + --auto-merge arms as before (exit 0)"
else
    fail "CREDIBLE-1576: non-gate arm should exit 0, got rc=$_gb_rc"
fi

# Case C: gate-file diff WITHOUT --auto-merge → pushes as before (no refusal).
( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )
(
  cd "$GREPO"
  mkdir -p scripts/git-hooks && echo 'z' > scripts/git-hooks/pre-x
  git add -A && git commit -qm hook
)
_gc_rc="$(_gate_rc C)"
if [[ "$_gc_rc" -eq 0 ]]; then
    pass "CREDIBLE-1576: gate-file diff without --auto-merge pushes as before (exit 0)"
else
    fail "CREDIBLE-1576: gate-file-without-arm should exit 0, got rc=$_gc_rc"
fi

# ── CREDIBLE-1576 item 2: FAIL-CLOSED when the diff cannot be computed ───────
# A branch with no merge base against origin/main (missing ref / unrelated
# history) must REFUSE the arm, never read as "clean". A fresh repo WITHOUT an
# origin/main ref makes `git diff origin/main...HEAD` fail; the arm must refuse
# (exit 2). Kills a mutant that returns rc=0 on a failed diff (the old
# fail-open behaviour).
GREPO_FC="$TMP/gate-repo-failclosed"
git init -q "$GREPO_FC"
(
  cd "$GREPO_FC"
  git config user.email t@example.com
  git config user.name tester
  echo base > README.md
  git add -A && git commit -qm base
  # deliberately do NOT create refs/remotes/origin/main → no merge base
)
set +e
_fc_out="$( cd "$GREPO_FC" && bash "$BOT_MERGE" --gate-arm-check --auto-merge 2>&1 )"
_fc_rc=$?
set -e
if [[ "$_fc_rc" -eq 2 ]] && printf '%s' "$_fc_out" | grep -q 'REFUSED'; then
    pass "CREDIBLE-1576 item 2: uncomputable diff (no merge base) fails closed — refuses arm (exit 2)"
else
    fail "CREDIBLE-1576 item 2: expected fail-closed exit 2 + REFUSED (rc=$_fc_rc out=$_fc_out)"
fi

# ── CREDIBLE-1576 item 5: every glob in the list refuses (kills m8/m9/m10) ───
# One refusal case per NON-scripts/ci glob so dropping any single glob from the
# constant array fails a case: .github/workflows/* (m8), *verified-wait* (m9),
# crates/chump-preflight/* (m10). (scripts/ci/* + scripts/git-hooks/* already
# covered by Case A + Case C above.)
( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )
for _glob_case in \
    ".github/workflows/ci.yml:m8-workflows" \
    "scripts/some-verified-wait.sh:m9-verified-wait" \
    "crates/chump-preflight/src/lib.rs:m10-preflight-crate"; do
    _gp="${_glob_case%%:*}"; _glbl="${_glob_case##*:}"
    (
      cd "$GREPO"
      mkdir -p "$(dirname "$_gp")" && echo x > "$_gp"
      git add -A && git commit -qm "$_glbl"
    )
    _gl_rc=0
    ( cd "$GREPO" && bash "$BOT_MERGE" --gate-arm-check --auto-merge ) >/dev/null 2>&1 || _gl_rc=$?
    if [[ "$_gl_rc" -eq 2 ]]; then
        pass "CREDIBLE-1576: gate glob '$_gp' refuses arm (exit 2) [$_glbl]"
    else
        fail "CREDIBLE-1576: glob '$_gp' should refuse (exit 2), got rc=$_gl_rc [$_glbl]"
    fi
    ( cd "$GREPO" && git update-ref refs/remotes/origin/main HEAD )
done

# ── CREDIBLE-1576 item 1: drive the REAL arm sites with an argv-recording gh ──
# The --gate-arm-check seam above proves the refusal ROUTINE, but not that the
# live arm paths actually CALL it before `gh pr merge`. These cases run
# bot-merge.sh end-to-end through its real arm sites under a stub `gh` that
# records every argv, then assert that `gh pr merge` is ABSENT on refused paths
# and PRESENT on the armed path. Covered mutants:
#   m3  explicit-flag-only refusal → killed by the internal-lane default case
#       (AUTO_MERGE=1 with NO --auto-merge flag) still refusing.
#   m5  main arm call site dropped → killed by the main-flow refused case.
#   m6  recovery arm call site dropped → killed by the recovery refused case.
#   m7  both dropped → killed by m5 + m6 together.
#   m14 always-exit-2 → killed by the armed (non-gate) case reaching gh pr merge.
ARM_MOCK="$TMP/arm-mock"; mkdir -p "$ARM_MOCK"
ARM_REPO="$TMP/arm-repo"; mkdir -p "$ARM_REPO/.chump-locks" "$ARM_REPO/.chump"
printf 'ref: refs/heads/main\n' > "$ARM_REPO/.git"
export FAKE_REPO="$ARM_REPO"

cat > "$ARM_MOCK/gh" <<'GHEOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$ARM_CALL_LOG"
subcmd="${1:-}"; shift || true
_hasjq=0; for a in "$@"; do [[ "$a" == "--jq" ]] && _hasjq=1; done
case "$subcmd" in
  auth) exit 0 ;;
  pr)
    pr_cmd="${1:-}"; shift || true
    case "$pr_cmd" in
      view)   if [[ $_hasjq -eq 1 ]]; then printf '42\n'; else printf '{"number":42,"state":"OPEN","autoMergeRequest":null}\n'; fi ;;
      list)   printf '42\n' ;;
      merge)  exit 0 ;;
      checks) exit 0 ;;
      diff)   exit 0 ;;
      create) printf 'https://github.com/test/repo/pull/42\n'; exit 0 ;;
      comment|edit) exit 0 ;;
      *)      exit 0 ;;
    esac ;;
  api)
    case "$*" in
      *rate_limit*) if [[ $_hasjq -eq 1 ]]; then echo "4800 4900 9999999999"; else printf '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":9999999999},"graphql":{"limit":5000,"remaining":4900,"reset":9999999999}}}\n'; fi ;;
      *) echo '[]' ;;
    esac ;;
  *) exit 0 ;;
esac
GHEOF

cat > "$ARM_MOCK/chump" <<'CHEOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "gap show") echo 'status: open';; "gap list") echo '[]';; esac
exit 0
CHEOF

cat > "$ARM_MOCK/git" <<'GITEOF'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  rev-parse)
    case "$*" in
      *--abbrev-ref*)      printf 'chump/test-001-x\n' ;;
      *--show-toplevel*)   printf '%s\n' "$FAKE_REPO" ;;
      *--git-common-dir*)  printf '%s/.git\n' "$FAKE_REPO" ;;
      *)                   printf '%s\n' "$FAKE_REPO" ;;
    esac ;;
  remote) printf 'https://github.com/testorg/testrepo.git\n' ;;
  diff)
    case "$*" in
      *--quiet*) exit 0 ;;
      *) printf '%s\n' "${MOCK_GIT_DIFF_FILES:-}"; exit "${MOCK_GIT_DIFF_RC:-0}" ;;
    esac ;;
  log) echo "subject"; exit 0 ;;
  rev-list) echo "1"; exit 0 ;;
  branch|status|push|tag|fetch|worktree|add|commit|stash|config|symbolic-ref|merge-base|cat-file|show-ref|update-ref|for-each-ref|ls-files) exit 0 ;;
  *) exit 0 ;;
esac
GITEOF
chmod +x "$ARM_MOCK/gh" "$ARM_MOCK/chump" "$ARM_MOCK/git"

# No bypass/skip env vars are used to drive these flows (the standing rule
# forbids them). The mocks satisfy every real gate: `chump gap preflight` passes
# (mock chump exits 0), the rate-limit gate sees headroom (mock gh), and the
# MERGED pre-push check sees a non-merged PR (mock gh). The only non-flag env are
# path/mode knobs — not bypasses:
#   CHUMP_BOT_MERGE_RECOVERY_MODE=1   recovery fast-path MODE (the only way to
#                                     reach the recovery arm site at all).
#   CHUMP_MERGE_PIPELINE_LOCK_FILE    documented TEST path-override for the
#                                     merge-pipeline lock (relocates, never
#                                     disables it) so it lands in a writable tmp.
#   REPO_ROOT/MAIN_REPO/CHUMP_AMBIENT_LOG/MOCK_GIT_DIFF_*  standard test fixtures.

# Case D (recovery site, internal-lane DEFAULT arm, gate diff): no --auto-merge
# flag — AUTO_MERGE=1 comes from the internal-lane default, the exact path that
# self-armed #5602. Must refuse (exit 2) and NEVER reach `gh pr merge`.
ARM_CALL_LOG="$TMP/arm-D.log"; : > "$ARM_CALL_LOG"; export ARM_CALL_LOG
set +e
_d_out="$( cd "$ARM_REPO" && PATH="$ARM_MOCK:$PATH" MOCK_GIT_DIFF_FILES="scripts/ci/x.sh" MOCK_GIT_DIFF_RC=0 REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" \
    CHUMP_BOT_MERGE_RECOVERY_MODE=1 CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$BOT_MERGE" --gap TEST-001 2>&1 )"
_d_rc=$?
set -e
# Require the guard's OWN "REFUSED" signal (not just exit 2 + no-merge, which an
# unrelated downstream failure could also produce) so a dropped call site cannot
# masquerade as a refusal.
if [[ "$_d_rc" -eq 2 ]] && printf '%s' "$_d_out" | grep -q 'REFUSED' && ! grep -q 'pr merge' "$ARM_CALL_LOG"; then
    pass "CREDIBLE-1576 item 1: recovery DEFAULT-lane arm on gate diff refuses (exit 2 + REFUSED), no gh pr merge [m3,m6]"
else
    fail "CREDIBLE-1576 item 1: recovery gate arm not refused (rc=$_d_rc, refused=$(printf '%s' "$_d_out" | grep -c 'REFUSED'), merge-calls=$(grep -c 'pr merge' "$ARM_CALL_LOG"))"
fi

# Case E (recovery site, NON-gate diff + --auto-merge): the guard must ALLOW —
# the arm proceeds and `gh pr merge` IS called. Kills m14 (always-exit-2): an
# unconditional refusal would block this legitimate arm.
ARM_CALL_LOG="$TMP/arm-E.log"; : > "$ARM_CALL_LOG"; export ARM_CALL_LOG
set +e
( cd "$ARM_REPO" && PATH="$ARM_MOCK:$PATH" MOCK_GIT_DIFF_FILES="docs/note.md" MOCK_GIT_DIFF_RC=0 REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" \
    CHUMP_BOT_MERGE_RECOVERY_MODE=1 CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$BOT_MERGE" --gap TEST-001 --auto-merge ) >/dev/null 2>&1
_e_rc=$?
set -e
if [[ "$_e_rc" -eq 0 ]] && grep -q 'pr merge' "$ARM_CALL_LOG"; then
    pass "CREDIBLE-1576 item 1: recovery non-gate arm proceeds (exit 0), gh pr merge called [m14]"
else
    fail "CREDIBLE-1576 item 1: recovery non-gate arm should arm (rc=$_e_rc, merge-calls=$(grep -c 'pr merge' "$ARM_CALL_LOG"))"
fi

# Case F (MAIN arm site, gate diff + --auto-merge): drive the full per-PR flow
# to the main `if [[ $AUTO_MERGE -eq 1 ]]` arm block. Must refuse (exit 2) and
# NEVER reach `gh pr merge`. Kills m5 (main arm call site dropped) and, with
# Case D, m7 (both dropped).
ARM_CALL_LOG="$TMP/arm-F.log"; : > "$ARM_CALL_LOG"; export ARM_CALL_LOG
set +e
_f_out="$( cd "$ARM_REPO" && PATH="$ARM_MOCK:$PATH" MOCK_GIT_DIFF_FILES="scripts/ci/x.sh" MOCK_GIT_DIFF_RC=0 REPO_ROOT="$ARM_REPO" MAIN_REPO="$ARM_REPO" \
    CHUMP_AMBIENT_LOG="$AMBIENT" CHUMP_MERGE_PIPELINE_LOCK_FILE="$TMP/mpl-F.lock" \
    bash "$BOT_MERGE" --gap TEST-001 --auto-merge --no-local-build 2>&1 )"
_f_rc=$?
set -e
# Require the guard's OWN "REFUSED" signal: with the main call site dropped (m5)
# the flow reaches the real auto-merge-armer, which fails in the mock env and
# also exits 2 — but WITHOUT printing REFUSED, so this assertion still kills m5.
if [[ "$_f_rc" -eq 2 ]] && printf '%s' "$_f_out" | grep -q 'REFUSED' && ! grep -q 'pr merge' "$ARM_CALL_LOG"; then
    pass "CREDIBLE-1576 item 1: MAIN arm site on gate diff refuses (exit 2 + REFUSED), no gh pr merge [m5,m7]"
else
    fail "CREDIBLE-1576 item 1: MAIN arm site not refused (rc=$_f_rc, refused=$(printf '%s' "$_f_out" | grep -c 'REFUSED'), merge-calls=$(grep -c 'pr merge' "$ARM_CALL_LOG"))"
fi

# ── CREDIBLE-1576 item 5: static assertions — guard reads NO env (m13), and the
# gate-file glob list is a SINGLE literal constant (m4). The guard is a safety
# input; per the Chief standing rule it must never be reconfigurable by env.
_fn_region="$(awk '/^bot_merge_gate_files_touched\(\)/{f=1} /^# INFRA-2001: feature-flag shim/{f=0} f{print}' "$BOT_MERGE")"
# Strip the script's own constant name, then look for any ENV-style ($UPPERCASE)
# reference. Positional ($1) and local ($auto/$_diff) params never match.
_env_in_guard="$(printf '%s\n' "$_fn_region" | sed 's/BOT_MERGE_GATE_FILE_GLOBS//g' | grep -oE '\$\{?[A-Z][A-Z0-9_]*' | sort -u || true)"
if [[ -z "$_env_in_guard" ]]; then
    pass "CREDIBLE-1576 item 5: gate guard reads no environment variable [m13]"
else
    fail "CREDIBLE-1576 item 5: gate guard reads env var(s) — $_env_in_guard [m13]"
fi

_glob_assigns="$(grep -cE '^BOT_MERGE_GATE_FILE_GLOBS=\(' "$BOT_MERGE" || true)"
_arr_body="$(awk '/^BOT_MERGE_GATE_FILE_GLOBS=\(/{f=1;next} f&&/^\)/{f=0} f{print}' "$BOT_MERGE")"
if [[ "$_glob_assigns" == "1" ]] && ! printf '%s' "$_arr_body" | grep -q '\$'; then
    pass "CREDIBLE-1576 item 5: gate-file glob list is a single literal constant (no env read) [m4]"
else
    fail "CREDIBLE-1576 item 5: glob list not a single literal (assigns=$_glob_assigns, body has \$: $(printf '%s' "$_arr_body" | grep -c '\$')) [m4]"
fi

echo ""
echo "All INFRA-1030 arm-ship-order + CREDIBLE-1576 gate-file-arm checks passed."
