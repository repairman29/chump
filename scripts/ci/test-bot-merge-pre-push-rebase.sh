#!/usr/bin/env bash
# scripts/ci/test-bot-merge-pre-push-rebase.sh — RESILIENT-325
#
# Verifies the pre-push auto-rebase in scripts/coord/bot-merge.sh: when the
# branch is 1..threshold commits behind origin/main immediately before push,
# bot-merge rebases onto fresh origin/main in-place (instead of silently
# pushing stale) so the conflict window shrinks to ~0.
#
#   1. The block is present + calls `git rebase` when 0 < BEHIND <= threshold.
#   2. Rebase success emits kind=pre_push_rebase_applied and does NOT fail.
#   3. Rebase conflict emits kind=pre_push_rebase_conflict, aborts the rebase,
#      and exits 3 via _bm_fail "pre-push-rebase".
#   4. BEHIND=0 does nothing (no rebase attempted, no ambient event).
#   5. EVENT_REGISTRY.yaml registers both new event kinds.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static-grep checks ────────────────────────────────────────────────────
grep -q "RESILIENT-325 auto-rebase" "$BOT_MERGE" \
    || fail "RESILIENT-325 banner missing from bot-merge.sh"
grep -q 'run_timed_hb "git rebase (pre-push, RESILIENT-325)" 60 git rebase' "$BOT_MERGE" \
    || fail "pre-push auto-rebase git-rebase call missing"
grep -q '"kind":"pre_push_rebase_applied"' "$BOT_MERGE" \
    || fail "pre_push_rebase_applied ambient emission missing"
grep -q '"kind":"pre_push_rebase_conflict"' "$BOT_MERGE" \
    || fail "pre_push_rebase_conflict ambient emission missing"
grep -q '_bm_fail "pre-push-rebase" 3' "$BOT_MERGE" \
    || fail "exit code 3 + label 'pre-push-rebase' not wired via _bm_fail"
ok "static grep: auto-rebase block present + both ambient kinds + exit 3 on conflict"

# ── 2. EVENT_REGISTRY contains both new events with required fields ─────────
python3 - "$REG" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
for kind in ("pre_push_rebase_applied", "pre_push_rebase_conflict"):
    assert f"kind: {kind}" in text, f"{kind} not registered"
    m = re.search(rf"- kind: {kind}.*?(?=\n  -|\Z)", text, re.S)
    assert m, f"could not extract {kind} registry block"
    block = m.group(0)
    for f in ("ts", "kind", "branch", "behind", "phase"):
        assert f in block, f"fields_required missing {f!r} in {kind}: {block}"
PY
ok "EVENT_REGISTRY.yaml registers pre_push_rebase_applied + pre_push_rebase_conflict"

# ── 3. Simulate the block by extracting + executing it ──────────────────────
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/git" <<'EOF'
#!/usr/bin/env bash
# Fake git: rev-list reports a chosen BEHIND; fetch is a no-op; rebase
# succeeds or fails per TEST_REBASE_RESULT; rebase --abort is a no-op.
case "$1" in
    rev-list)
        echo "${TEST_BEHIND:-0}"
        ;;
    fetch)
        exit 0
        ;;
    rebase)
        if [[ "$2" == "--abort" ]]; then
            exit 0
        fi
        if [[ "${TEST_REBASE_RESULT:-ok}" == "conflict" ]]; then
            exit 1
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$TMP/fakebin/git"

RUNNER="$TMP/run-pre-push-rebase-block.sh"
cat >"$RUNNER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

REMOTE=origin
BASE_BRANCH=main
BRANCH=test/pre-push-rebase-fixture
DRY_RUN=0
NO_MERGE_DRIVER=0
LOCK_DIR="$AMB_DIR/.chump-locks"
REPO_ROOT="$AMB_DIR"

red()  { echo "RED: $*"; }
info() { echo "INFO: $*"; }
run_timed_hb() { shift 2; "$@"; }   # drop label + timeout, just run
_bm_fail() { echo "FAIL label=$1 code=$2 msg=$3"; exit "$2"; }

EOF
awk '
    /RESILIENT-325 auto-rebase/ {grab=1}
    grab {print}
    /^# ── INFRA-993: scratch-commit guard/ {exit}
' "$BOT_MERGE" >>"$RUNNER"

chmod +x "$RUNNER"

# Case A: BEHIND = 0 → no rebase attempted, no ambient event.
AMB_DIR="$TMP/caseA"
mkdir -p "$AMB_DIR/.chump-locks"
PATH="$TMP/fakebin:$PATH" AMB_DIR="$AMB_DIR" TEST_BEHIND=0 bash "$RUNNER"
rc=$?
[[ "$rc" -eq 0 ]] || fail "BEHIND=0 should pass, got rc=$rc"
[[ ! -s "$AMB_DIR/.chump-locks/ambient.jsonl" ]] \
    || fail "BEHIND=0 should NOT emit, but ambient has: $(cat "$AMB_DIR/.chump-locks/ambient.jsonl")"
ok "BEHIND=0 → no rebase attempted, no ambient event"

# Case B: BEHIND = 5 (under threshold), rebase succeeds → auto-rebase applied.
AMB_DIR="$TMP/caseB"
mkdir -p "$AMB_DIR/.chump-locks"
PATH="$TMP/fakebin:$PATH" AMB_DIR="$AMB_DIR" TEST_BEHIND=5 TEST_REBASE_RESULT=ok bash "$RUNNER"
rc=$?
[[ "$rc" -eq 0 ]] || fail "BEHIND=5 clean rebase should pass, got rc=$rc"
amb="$AMB_DIR/.chump-locks/ambient.jsonl"
[[ -s "$amb" ]] || fail "BEHIND=5 should emit pre_push_rebase_applied, file empty/missing"
line="$(cat "$amb")"
for f in '"kind":"pre_push_rebase_applied"' '"behind":5' '"phase":"pre-push"' '"branch":"test/pre-push-rebase-fixture"'; do
    grep -q "$f" <<<"$line" || fail "ambient line missing $f: $line"
done
ok "BEHIND=5 + clean rebase → pre_push_rebase_applied emitted, no failure (this is the behavior that fails without RESILIENT-325 — old code silently pushed stale instead)"

# Case C: BEHIND = 5, rebase hits a conflict → aborted + exit 3.
AMB_DIR="$TMP/caseC"
mkdir -p "$AMB_DIR/.chump-locks"
set +e
PATH="$TMP/fakebin:$PATH" AMB_DIR="$AMB_DIR" TEST_BEHIND=5 TEST_REBASE_RESULT=conflict bash "$RUNNER"
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "BEHIND=5 conflicted rebase should exit 3, got rc=$rc"
amb="$AMB_DIR/.chump-locks/ambient.jsonl"
[[ -s "$amb" ]] || fail "BEHIND=5 conflict should emit pre_push_rebase_conflict, file empty/missing"
line="$(cat "$amb")"
for f in '"kind":"pre_push_rebase_conflict"' '"behind":5' '"phase":"pre-push"'; do
    grep -q "$f" <<<"$line" || fail "ambient line missing $f: $line"
done
ok "BEHIND=5 + rebase conflict → pre_push_rebase_conflict emitted + exit 3"

# Case D: BEHIND = 30 > threshold 15 → falls through to the existing
# INFRA-995 stale_branch_blocked path, NOT the auto-rebase path.
AMB_DIR="$TMP/caseD"
mkdir -p "$AMB_DIR/.chump-locks"
set +e
PATH="$TMP/fakebin:$PATH" AMB_DIR="$AMB_DIR" TEST_BEHIND=30 bash "$RUNNER"
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "BEHIND=30 should exit 3 via stale-branch path, got rc=$rc"
amb="$AMB_DIR/.chump-locks/ambient.jsonl"
line="$(cat "$amb")"
grep -q '"kind":"stale_branch_blocked"' <<<"$line" \
    || fail "BEHIND=30 should still hit stale_branch_blocked, not auto-rebase: $line"
ok "BEHIND=30 (over threshold) → still hard-blocked via stale_branch_blocked, no unattended rebase"

echo
echo "All bot-merge pre-push auto-rebase tests passed."
