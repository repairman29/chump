#!/usr/bin/env bash
# test-pr-watch-shepherd-smoke.sh — INFRA-354 smoke test.
#
# Verifies the shepherd:
#   1. Exits cleanly when no DIRTY-after-arm PRs exist (writes heartbeat,
#      emits one ambient event with scanned=0).
#   2. Honors CHUMP_PR_WATCH_SHEPHERD=0 bypass.
#   3. Exits 1 (precondition fail) when not in a git checkout.
#
# Does NOT exercise the full DIRTY-recovery path because that requires a
# live PR with auto-merge armed in the GitHub repo — covered by manual
# smoke + by the existing pr-watch.sh tests (the shepherd just orchestrates
# pr-watch, it doesn't reimplement the rebase logic).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SHEPHERD="$REPO_ROOT/scripts/ops/pr-watch-shepherd.sh"

if [[ ! -x "$SHEPHERD" ]]; then
    echo "[FAIL] $SHEPHERD not executable"
    exit 1
fi

# ── Test 1: bypass env ───────────────────────────────────────────────────
echo "Test 1: CHUMP_PR_WATCH_SHEPHERD=0 must exit 0 immediately"
out=$(CHUMP_PR_WATCH_SHEPHERD=0 bash "$SHEPHERD" 2>&1)
rc=$?
[[ $rc -eq 0 ]] || { echo "[FAIL] bypass exited $rc; expected 0"; echo "$out"; exit 1; }
echo "$out" | grep -q "CHUMP_PR_WATCH_SHEPHERD=0 — bypass" || {
    echo "[FAIL] bypass message missing"; echo "$out"; exit 1; }
echo "[PASS] bypass works"

# ── Test 2: not in a git checkout ────────────────────────────────────────
echo ""
echo "Test 2: outside a git checkout must exit 1"
TMP=$(mktemp -d)
cd "$TMP"
set +e
out=$(bash "$SHEPHERD" 2>&1)
rc=$?
set -e
cd "$REPO_ROOT"
rm -rf "$TMP"
[[ $rc -eq 1 ]] || { echo "[FAIL] no-git-checkout exited $rc; expected 1"; echo "$out"; exit 1; }
echo "$out" | grep -q "not in a git checkout" || {
    echo "[FAIL] expected error message missing"; echo "$out"; exit 1; }
echo "[PASS] precondition check works"

# ── Test 3: clean run (no DIRTY PRs) — heartbeat written, ambient event emitted ─
echo ""
echo "Test 3: clean run writes heartbeat + one ambient event"
HB=/tmp/chump-reaper-pr-watch.heartbeat
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
if [[ "$COMMON_DIR" == ".git" || "$COMMON_DIR" == "$REPO_ROOT/.git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$COMMON_DIR/.." && pwd)"
fi
AMBIENT="$MAIN_REPO/.chump-locks/ambient.jsonl"
# CI fresh-checkout fix: ensure the lock dir + ambient file exist so the
# shepherd can append to it. The dir is gitignored so a fresh runner has
# neither. Touching guarantees both exist; idempotent on developer
# machines where they already do.
mkdir -p "$MAIN_REPO/.chump-locks"
touch "$AMBIENT"
rm -f "$HB"
ambient_lines_before=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
# INFRA-385: PR_WATCH_MAX_PRS=0 short-circuits the per-PR loop AFTER
# the shepherd has scanned + emitted heartbeat + ambient event but
# BEFORE it tries to create ephemeral worktrees and invoke pr-watch on
# real DIRTY PRs. Pre-fix, dev machines with real DIRTY PRs in flight
# had the smoke test do live recovery work — flaky on git-auth corner
# cases and semantically wrong (a smoke test should not mutate real
# PRs). The cap is honored by the "(( PROCESSED >= MAX_PRS )) && break"
# guard at the top of the per-PR loop in pr-watch-shepherd.sh.
set +e
out=$(PR_WATCH_MAX_PRS=0 bash "$SHEPHERD" 2>&1)
rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "[FAIL] clean run exited $rc"; echo "$out"; exit 1; }
[[ -f "$HB" ]] || { echo "[FAIL] heartbeat not written at $HB"; exit 1; }
ambient_lines_after=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
new_lines=$((ambient_lines_after - ambient_lines_before))
if (( new_lines < 1 )); then
    echo "[FAIL] no ambient event emitted (before=$ambient_lines_before after=$ambient_lines_after)"
    exit 1
fi
# Verify the new ambient line is the pr_watch event we expect
new_event=$(tail -1 "$AMBIENT")
echo "$new_event" | grep -q '"kind":"pr_watch"' || {
    echo "[FAIL] last ambient event is not pr_watch: $new_event"; exit 1; }
echo "[PASS] heartbeat written; ambient event: $(echo "$new_event" | head -c 120)…"

# ── Test 4: watchdog now grades pr-watch ─────────────────────────────────
echo ""
echo "Test 4: reaper-heartbeat-watchdog includes pr-watch in default targets"
WATCHDOG="$REPO_ROOT/scripts/ops/reaper-heartbeat-watchdog.sh"
out=$(bash "$WATCHDOG" pr-watch 2>&1)
rc=$?
echo "$out" | grep -qE "pr-watch (heartbeated|has)" || {
    echo "[FAIL] watchdog didn't recognize pr-watch target. output:"; echo "$out"; exit 1; }
echo "[PASS] watchdog grades pr-watch"


# ── Test 5: --branch-override bypasses symbolic-ref check (INFRA-801) ────
# When pr-watch.sh runs from an ephemeral worktree (detached HEAD or wrong
# branch), it must NOT exit 4 ("symbolic-ref failed") when --branch-override
# is supplied. It will exit non-zero for other reasons (can't reach GitHub)
# but the specific exit-4 branch-mismatch error must not fire.
echo ""
echo "Test 5: --branch-override skips symbolic-ref check in detached-HEAD worktree"
PRWATCH="$REPO_ROOT/scripts/coord/pr-watch.sh"
TMP5=$(mktemp -d)
trap 'rm -rf "$TMP5"' EXIT
# Create a bare git repo so we can make a worktree with detached HEAD
git init --bare "$TMP5/bare.git" >/dev/null 2>&1
git clone "$TMP5/bare.git" "$TMP5/clone" >/dev/null 2>&1 || true
# If clone is empty (no commits), create a stub commit
(
    cd "$TMP5/clone" 2>/dev/null || true
    git config user.email "test@test" 2>/dev/null || true
    git config user.name "test" 2>/dev/null || true
    touch stub && git add stub 2>/dev/null || true
    git commit -m "stub" 2>/dev/null || true
    git checkout --detach HEAD 2>/dev/null || true  # detached HEAD
) 2>/dev/null || true

set +e
out5=$(cd "$TMP5/clone" && CHUMP_PR_WATCH=0 bash "$PRWATCH" 9999 --once --branch-override "some-branch" 2>&1)
rc5=$?
set -e
if [[ $rc5 -eq 4 ]]; then
    echo "[FAIL] pr-watch.sh exited 4 (symbolic-ref error) despite --branch-override"
    echo "  output: $out5"
    exit 1
fi
# The bypass env CHUMP_PR_WATCH=0 should short-circuit and exit 0 cleanly,
# confirming --branch-override was accepted and the symbolic-ref check skipped.
[[ $rc5 -eq 0 ]] || {
    echo "[FAIL] expected exit 0 with CHUMP_PR_WATCH=0 bypass, got $rc5"
    echo "  output: $out5"
    exit 1
}
echo "[PASS] --branch-override accepted (exit 0, no symbolic-ref error)"

echo ""
echo "[OK] all 5 shepherd / pr-watch smoke cases passed (INFRA-354 + INFRA-801)"
