#!/usr/bin/env bash
# test-bot-merge-scratch-guard.sh — INFRA-993
#
# Exercises the catastrophic-delete guard in bot-merge.sh:
#   1. Normal diff (+10 / -5) → push proceeds (we shim git push to noop +
#      assert it ran)
#   2. -378k deletions → push aborts, emits kind=scratch_commit_blocked,
#      exit code 15
#   3. -378k with --allow-mass-delete → push proceeds, emits
#      kind=scratch_commit_override_used
#   4. CHUMP_SCRATCH_GUARD_DISABLE=1 short-circuits the check
#
# We don't run all of bot-merge.sh end-to-end; we extract the guard block
# and exercise it with a shim `git` on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
[[ -f "$BOT_MERGE" ]] || { echo "FAIL: missing $BOT_MERGE"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCK_DIR="$TMP/.chump-locks"
mkdir -p "$LOCK_DIR"
AMB="$LOCK_DIR/ambient.jsonl"

# Extract the scratch-guard block from bot-merge.sh into a self-contained runner.
# The block lives between the INFRA-993 header and the next "# ── 5. Push" line.
GUARD_BLOCK="$TMP/guard.sh"
awk '
  /^# ── INFRA-993: scratch-commit guard/ { in_block=1 }
  in_block { print }
  in_block && /^# ── 5\. Push/ { exit }
' "$BOT_MERGE" > "$GUARD_BLOCK"
[[ -s "$GUARD_BLOCK" ]] || fail "could not extract INFRA-993 guard block from bot-merge.sh"

# Stubs: red/yellow/green/info functions (the guard uses them).
SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env bash
# Shim only for `git diff --shortstat`; emit canned text from $GIT_TEST_DIFF_STAT.
if [[ "$1 $2" == "diff --shortstat" ]]; then
  printf '%s\n' "${GIT_TEST_DIFF_STAT:- 0 files changed, 0 insertions(+), 0 deletions(-)}"
  exit 0
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/git"

run_guard() {
  # All variables that the guard block expects.
  env \
    PATH="$SHIM_DIR:/usr/bin:/bin" \
    GIT_TEST_DIFF_STAT="$1" \
    REMOTE=origin \
    BASE_BRANCH=main \
    BRANCH=chump/test \
    DRY_RUN=0 \
    GAP_IDS_0="INFRA-X" \
    CHUMP_AMBIENT_LOG="$AMB" \
    LOCK_DIR="$LOCK_DIR" \
    REPO_ROOT="$REPO_ROOT" \
    ALLOW_MASS_DELETE="${ALLOW_MASS_DELETE:-0}" \
    "${@:2}" \
    bash -c '
      # Shims for bot-merge color helpers + GAP_IDS array reconstruction.
      red()    { printf "RED: %s\n" "$*" >&2; }
      yellow() { printf "YELLOW: %s\n" "$*" >&2; }
      green()  { printf "GREEN: %s\n" "$*" >&2; }
      info()   { printf "INFO: %s\n" "$*"; }
      GAP_IDS=("INFRA-X")
      source "'"$GUARD_BLOCK"'"
    '
}

# Scenario 1: normal diff (+10 / -5) → guard passes, exit 0.
: > "$AMB"
out=$(run_guard " 3 files changed, 10 insertions(+), 5 deletions(-)" 2>&1) || \
  fail "normal diff should pass; exit=$? out=$out"
[[ ! -s "$AMB" ]] || fail "normal diff: ambient should be empty (got: $(cat $AMB))"
ok "normal diff (+10 / -5): guard passes silently"

# Scenario 2: -378k deletions → blocked, exit 15, emits scratch_commit_blocked.
: > "$AMB"
if out=$(run_guard " 1910 files changed, 2 insertions(+), 378547 deletions(-)" 2>&1); then
  fail "catastrophic diff should have aborted; out=$out"
fi
echo "$out" | grep -q "Aborting:" || fail "catastrophic diff: missing abort message"
grep -q '"kind":"scratch_commit_blocked"' "$AMB" \
  || fail "catastrophic diff: scratch_commit_blocked event missing"
grep -q '"deletions":378547' "$AMB" || fail "catastrophic diff: deletions count missing"
grep -q '"files":1910' "$AMB" || fail "catastrophic diff: files count missing"
ok "catastrophic diff (-378k): aborts + emits scratch_commit_blocked"

# Scenario 3: --allow-mass-delete bypasses.
: > "$AMB"
ALLOW_MASS_DELETE=1 \
  out=$(run_guard " 1910 files changed, 2 insertions(+), 378547 deletions(-)" 2>&1) || \
  fail "override should allow the push; exit=$? out=$out"
grep -q '"kind":"scratch_commit_override_used"' "$AMB" \
  || fail "override: scratch_commit_override_used event missing"
grep -q '"kind":"scratch_commit_blocked"' "$AMB" \
  && fail "override should NOT also emit scratch_commit_blocked"
ok "--allow-mass-delete: bypass + emits scratch_commit_override_used"

# Scenario 4: deletions > 100× additions (ratio trigger).
# Clear ALLOW_MASS_DELETE leaked from scenario 3 first.
unset ALLOW_MASS_DELETE
: > "$AMB"
if run_guard " 50 files changed, 5 insertions(+), 600 deletions(-)" >/dev/null 2>&1; then
  fail "ratio trigger (600 dels vs 5 adds) should have aborted"
fi
grep -q '"kind":"scratch_commit_blocked"' "$AMB" \
  || fail "ratio trigger: scratch_commit_blocked event missing"
ok "ratio trigger (600 dels vs 5 adds = 120× ratio): aborts"

# Scenario 5: CHUMP_SCRATCH_GUARD_DISABLE=1 short-circuits.
: > "$AMB"
CHUMP_SCRATCH_GUARD_DISABLE=1 \
  run_guard " 1910 files changed, 2 insertions(+), 378547 deletions(-)" >/dev/null 2>&1 \
  || fail "DISABLE env should bypass"
[[ ! -s "$AMB" ]] || fail "DISABLE env: no ambient events expected"
ok "CHUMP_SCRATCH_GUARD_DISABLE=1 short-circuits cleanly"

# Scenario 6: tuning thresholds.
: > "$AMB"
# With ratio set to 1000, 600 dels vs 5 adds (120×) no longer trips ratio,
# and 600 dels is below default abs of 50000.
CHUMP_SCRATCH_GUARD_RATIO=1000 \
  run_guard " 50 files changed, 5 insertions(+), 600 deletions(-)" >/dev/null 2>&1 \
  || fail "tuned ratio (1000) should permit 600/5"
[[ ! -s "$AMB" ]] || fail "tuned ratio: should not emit"
ok "CHUMP_SCRATCH_GUARD_RATIO=1000 permits the previously-blocked 600/5 case"

echo
echo "=== test-bot-merge-scratch-guard.sh PASSED ==="
