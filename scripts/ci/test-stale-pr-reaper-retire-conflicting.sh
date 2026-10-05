#!/usr/bin/env bash
# test-stale-pr-reaper-retire-conflicting.sh — INFRA-3803 smoke test.
#
# Exercises the "retire stale + conflicting PRs" pass added to
# scripts/ops/stale-pr-reaper.sh (INFRA-3604 slice).
#
# Cases covered:
#   1. CONFLICTING PR younger than the stale threshold → left alone.
#   2. CONFLICTING PR ≥ threshold → closed + labeled `retired` + emit
#      kind=pr_retired_stale_conflicting (this is the same check whether or
#      not the cited gap was demoted — AC #1 and AC #3 collapse into one).
#   3. Already-`retired` PR → skipped (idempotent, no double-close).
#   4. `do-not-respawn` label → exempt, no close.
#   5. Non-CONFLICTING (e.g. CLEAN) PR, even if old → left alone.
#
# Network-free: stubs `gh` via PATH.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-pr-reaper.sh"

[[ -x "$REAPER" ]] || { echo "FAIL: $REAPER not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/.chump-locks"
export PATH="$TMP/bin:$PATH"

# Set up a real git repo so reaper_setup can find a worktree.
cd "$TMP"
git init -q --bare origin.git >/dev/null
git init -q -b main repo >/dev/null
cd "$TMP/repo"
git config user.email "test@chump.local"
git config user.name "Chump Test"
echo init > README.md
git add README.md && git commit -qm "init"
git remote add origin "$TMP/origin.git"
git push -q origin main

export REAPER_LOCK_DIR="$TMP/repo/.chump-locks"
mkdir -p "$REAPER_LOCK_DIR"
AMBIENT="$REAPER_LOCK_DIR/ambient.jsonl"

# Helper: PR-list JSON literal builder (mergeable field drives the new pass).
mk_pr_json() {
    local pr_num="$1" branch="$2" title="$3" mergeable="$4" created_at="$5" labels_json="$6"
    cat <<JSON
[{"number":$pr_num,"title":"$title","headRefName":"$branch","mergeable":"$mergeable","createdAt":"$created_at","labels":$labels_json}]
JSON
}

PR_FIXTURE="$TMP/prs.json"
echo "[]" > "$PR_FIXTURE"
PR_CLOSE_LOG="$TMP/pr-close.log"
PR_EDIT_LOG="$TMP/pr-edit.log"
LABEL_LIST_OUT="retired"
: > "$PR_CLOSE_LOG"
: > "$PR_EDIT_LOG"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "pr list "*)
        cat "$PR_FIXTURE"
        ;;
    "pr close "*)
        echo "\$*" >> "$PR_CLOSE_LOG"
        ;;
    "pr edit "*)
        echo "\$*" >> "$PR_EDIT_LOG"
        ;;
    "label list "*)
        echo "$LABEL_LIST_OUT"
        ;;
    "label create "*) ;;
    "pr view "*) echo "1970-01-01T00:00:00Z" ;;
    "pr diff "*) echo "" ;;
    *) echo "" ;;
esac
EOF
chmod +x "$TMP/bin/gh"

# Stub `chump` — not exercised by this pass but sourced by reaper instrumentation.
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/chump"

COMMON_ENV=(
    REMOTE=origin
    BASE=main
    REAPER_LOCK_DIR="$REAPER_LOCK_DIR"
    REAPER_REPO_ROOT="$TMP/repo"
    CHUMP_REAPER_PARITY_CHECK=0
    CHUMP_PR_AUTO_RESPAWN=0
)

old_iso_days() {
    python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) - timedelta(days=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

count_kind() {
    local kind="$1" n
    [[ -s "$AMBIENT" ]] || { echo 0; return; }
    n=$(grep -c "\"kind\":\"${kind}\"" "$AMBIENT" 2>/dev/null || true)
    echo "${n:-0}"
}

reset_state() {
    : > "$AMBIENT"
    : > "$PR_CLOSE_LOG"
    : > "$PR_EDIT_LOG"
}

PASS=0
FAIL=0
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS"; PASS=$((PASS+1)); }

# ── Test 1: CONFLICTING but young — left alone ──────────────────────────────
echo "Test 1: CONFLICTING PR younger than stale threshold is left alone"
reset_state
mk_pr_json 2001 chump/test-young "INFRA-9101: young conflict" CONFLICTING "$(old_iso_days 2)" '[]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_RETIRE_STALE_DAYS=7 "$REAPER" --dry-run >/dev/null 2>&1 || true
if [[ "$(count_kind pr_retired_stale_conflicting)" == "0" && ! -s "$PR_CLOSE_LOG" ]]; then
    pass
else
    fail "young CONFLICTING PR triggered a retire; ambient: $(cat "$AMBIENT")"
fi

# ── Test 2: CONFLICTING ≥ threshold — closed + labeled + emit ───────────────
echo "Test 2: CONFLICTING PR >= stale threshold is retired"
reset_state
mk_pr_json 2002 chump/test-stale "INFRA-9102: stale conflict" CONFLICTING "$(old_iso_days 10)" '[]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_RETIRE_STALE_DAYS=7 "$REAPER" >/dev/null 2>&1 || true
if [[ "$(count_kind pr_retired_stale_conflicting)" -ge 1 \
   && -s "$PR_CLOSE_LOG" \
   && "$(grep -c 'pr close 2002' "$PR_CLOSE_LOG")" -ge 1 \
   && "$(grep -c 'pr edit 2002 --add-label retired' "$PR_EDIT_LOG")" -ge 1 \
   && "$(grep -c '"gap_ids":"INFRA-9102"' "$AMBIENT")" -ge 1 ]]; then
    pass
else
    fail "expected close + retired label + emit
    ambient: $(cat "$AMBIENT")
    close log: $(cat "$PR_CLOSE_LOG")
    edit log: $(cat "$PR_EDIT_LOG")"
fi

# ── Test 3: already-retired PR — skipped, idempotent ────────────────────────
echo "Test 3: already-labeled retired PR is skipped"
reset_state
mk_pr_json 2003 chump/test-already "INFRA-9103: already retired" CONFLICTING "$(old_iso_days 30)" '[{"name":"retired"}]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_RETIRE_STALE_DAYS=7 "$REAPER" >/dev/null 2>&1 || true
if [[ "$(count_kind pr_retired_stale_conflicting)" == "0" && ! -s "$PR_CLOSE_LOG" ]]; then
    pass
else
    fail "already-retired PR was re-processed; ambient: $(cat "$AMBIENT")"
fi

# ── Test 4: do-not-respawn label — exempt ───────────────────────────────────
echo "Test 4: do-not-respawn label exempts PR from retirement"
reset_state
mk_pr_json 2004 chump/test-exempt "INFRA-9104: exempt" CONFLICTING "$(old_iso_days 30)" '[{"name":"do-not-respawn"}]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_RETIRE_STALE_DAYS=7 "$REAPER" >/dev/null 2>&1 || true
if [[ "$(count_kind pr_retired_stale_conflicting)" == "0" && ! -s "$PR_CLOSE_LOG" ]]; then
    pass
else
    fail "do-not-respawn label not honored by retirement pass; ambient: $(cat "$AMBIENT")"
fi

# ── Test 5: non-CONFLICTING PR, even if old — left alone ────────────────────
echo "Test 5: CLEAN (non-conflicting) PR, even if old, is left alone"
reset_state
mk_pr_json 2005 chump/test-clean "INFRA-9105: clean old" MERGEABLE "$(old_iso_days 30)" '[]' > "$PR_FIXTURE"
env "${COMMON_ENV[@]}" CHUMP_RETIRE_STALE_DAYS=7 "$REAPER" >/dev/null 2>&1 || true
if [[ "$(count_kind pr_retired_stale_conflicting)" == "0" && ! -s "$PR_CLOSE_LOG" ]]; then
    pass
else
    fail "clean/mergeable old PR was incorrectly retired; ambient: $(cat "$AMBIENT")"
fi

echo ""
echo "=== INFRA-3803 stale+conflicting retirement test: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
