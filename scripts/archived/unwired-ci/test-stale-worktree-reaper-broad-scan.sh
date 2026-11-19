#!/usr/bin/env bash
# test-stale-worktree-reaper-broad-scan.sh — INFRA-2339 smoke test
#
# Verifies that stale-worktree-reaper.sh broadened scan correctly classifies
# worktrees with non-chump names:
#
# Structural checks (no live run needed):
#   T1: INFRA-2339 referenced in reaper header
#   T2: enumerate_tmp_rescue_orphans function present
#   T3: scan_source field present in worktree_reaped emit
#   T4: bash -n syntax check passes
#   T5: git-list source tag present in worktree-list pass
#   T6: CHUMP_RESCUE_SCAN_BASE override present (for testability)
#   T7: rescue-pattern pass emits scan_source=rescue-pattern annotation
#
# Behavioural checks (live reaper against synthetic fixtures):
#   T8:  chump-NN worktree → tmp_chump path (existing behaviour, not regressed)
#   T9:  ship-068 standalone old dir → found by rescue-pattern pass
#   T10: infra-NNN-fix standalone old dir → found by rescue-pattern pass
#   T11: fix-* standalone old dir → found by rescue-pattern pass
#   T12: *-rescue standalone old dir → found by rescue-pattern pass
#   T13: boring-random-dir (no pattern) → correctly skipped
#   T14: fresh rescue-pattern dir → correctly skipped (too young)
#   T15: reaper exits 0 with --dry-run in fixture environment
#
# Root cause this fixes: /tmp/infra-2446-fix (7.8 Gi) + /tmp/ship-068 (6.3 Gi)
# were invisible to the old /tmp/chump-* glob → 14 Gi of orphans.
#
# Run:
#   bash scripts/ci/test-stale-worktree-reaper-broad-scan.sh
# Exits non-zero on any failure.

set -euo pipefail

# RESILIENT-090: scrub GIT_* env vars leaked by pre-push hook before any git ops.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

REAPER="$REPO_ROOT/scripts/ops/stale-worktree-reaper.sh"
[[ -x "$REAPER" ]] || { echo "[FAIL] reaper not executable: $REAPER"; exit 1; }

PASS=0
FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-2339: stale-worktree-reaper broad-scan smoke test ==="

# ── Structural checks ─────────────────────────────────────────────────────────

# T1: INFRA-2339 referenced in reaper header.
if grep -q 'INFRA-2339' "$REAPER"; then
    ok "T1: INFRA-2339 referenced in reaper script"
else
    fail "T1: INFRA-2339 not referenced in reaper script"
fi

# T2: enumerate_tmp_rescue_orphans function present.
if grep -q 'enumerate_tmp_rescue_orphans' "$REAPER"; then
    ok "T2: enumerate_tmp_rescue_orphans function present"
else
    fail "T2: enumerate_tmp_rescue_orphans function missing"
fi

# T3: scan_source field present in worktree_reaped emit.
if grep -q 'scan_source' "$REAPER"; then
    ok "T3: scan_source field present in reaper emit"
else
    fail "T3: scan_source field missing from reaper emit"
fi

# T4: bash -n syntax check.
if bash -n "$REAPER" 2>/dev/null; then
    ok "T4: bash -n syntax check passes"
else
    fail "T4: reaper has bash syntax errors"
fi

# T5: git-list source tag wired into the git-worktree-list streaming pass.
if grep -qE 'git-list' "$REAPER"; then
    ok "T5: git-list source tag wired into git-worktree-list pass"
else
    fail "T5: git-list source tag missing from reaper"
fi

# T6: CHUMP_RESCUE_SCAN_BASE override present (for testability without /tmp).
if grep -q 'CHUMP_RESCUE_SCAN_BASE' "$REAPER"; then
    ok "T6: CHUMP_RESCUE_SCAN_BASE override present"
else
    fail "T6: CHUMP_RESCUE_SCAN_BASE override missing — rescue-pattern pass not testable"
fi

# T7: rescue-pattern scan emits scan_source=rescue-pattern in its info lines.
if grep -qE 'rescue-pattern' "$REAPER"; then
    ok "T7: rescue-pattern source annotation present in reaper"
else
    fail "T7: rescue-pattern source annotation missing"
fi

# ── Behavioural fixture tests ─────────────────────────────────────────────────
# Build a self-contained fake repo + fixture dirs.
# We use CHUMP_RESCUE_SCAN_BASE to redirect the rescue-pattern pass away from
# real /tmp (macOS mktemp uses /var/folders, so we create a stable subdir).

TMPBASE=$(mktemp -d -t infra-2339-test-XXXXXX)
trap 'rm -rf "$TMPBASE"' EXIT

FAKE_ORIGIN="$TMPBASE/origin.git"
FAKE_REPO="$TMPBASE/repo"
LOCKS_DIR="$FAKE_REPO/.chump-locks"
AMBIENT="$LOCKS_DIR/ambient.jsonl"
ARCHIVE_DIR="$FAKE_REPO/docs/archive/eval-runs"
WT_BASE="$FAKE_REPO/.claude/worktrees"
# Rescue-pattern fixtures live under a dedicated subdir so the scan is isolated.
RESCUE_BASE="$TMPBASE/rescue-scan-root"

mkdir -p "$FAKE_ORIGIN" "$LOCKS_DIR" "$ARCHIVE_DIR" "$WT_BASE" "$RESCUE_BASE"
touch "$AMBIENT"

# Stub lib files so the reaper stays self-contained against our fake repo.
mkdir -p "$FAKE_REPO/scripts/lib"

cat > "$FAKE_REPO/scripts/lib/reaper-instrumentation.sh" <<'LIB'
reaper_setup()               { REAPER_LOCK_DIR="${LOCKS_DIR:-/tmp}"; }
reaper_check_disk_headroom() { :; }
reaper_rotate_log()          { :; }
reaper_finish()              { :; }
LIB

cat > "$FAKE_REPO/scripts/lib/lease.sh" <<'LIB'
lease_iter()             { true; }
lease_worktree()         { echo ""; }
lease_is_fresh()         { return 1; }
lease_heartbeat_age_s()  { echo 9999; }
LIB

cat > "$FAKE_REPO/scripts/lib/worktree-iter.sh" <<'LIB'
emit_reaper_event() {
    local kind="$1" wt_path="$2" reason="${3:-}" extra="${4:-}"
    printf '{"ts":"%s","kind":"%s","worktree":"%s","reason":"%s"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$wt_path" "$reason" \
        "${extra:+,$extra}" \
        >> "${LOCKS_DIR}/ambient.jsonl" 2>/dev/null || true
}
LIB

# Init bare origin.
git init --bare "$FAKE_ORIGIN" -b main >/dev/null 2>&1

# Init fake repo.
git init -b main "$FAKE_REPO" >/dev/null 2>&1
git -C "$FAKE_REPO" remote add origin "file://$FAKE_ORIGIN"
git -C "$FAKE_REPO" config user.email "test@test.local"
git -C "$FAKE_REPO" config user.name "Test"

# Seed main.
echo "init" > "$FAKE_REPO/README"
git -C "$FAKE_REPO" add README
git -C "$FAKE_REPO" commit -q -m "init"
git -C "$FAKE_REPO" push -q -u origin main

# T8 fixture: chump-NN under WORKTREE_SCAN_PATHS (existing tmp_chump path).
WT_CHUMP="$TMPBASE/chump-9999"
mkdir -p "$WT_CHUMP"

# ── Rescue-pattern fixture helpers ────────────────────────────────────────────

# Create a standalone dir under RESCUE_BASE with old mtime (15h → beyond 12h threshold).
make_old_dir() {
    local name="$1"
    local d="$RESCUE_BASE/$name"
    mkdir -p "$d"
    touch -t "$(date -v-15H +%Y%m%d%H%M.%S 2>/dev/null \
        || date -d '15 hours ago' +%Y%m%d%H%M.%S 2>/dev/null \
        || echo "202601010000.00")" "$d" 2>/dev/null || true
    echo "$d"
}

# Create a FRESH standalone dir (mtime = now, well under 12h).
make_fresh_dir() {
    local name="$1"
    local d="$RESCUE_BASE/$name"
    mkdir -p "$d"
    echo "$d"
}

# T9: ship-NNN pattern.
make_old_dir "ship-068" >/dev/null
# T10: infra-NNN-fix pattern.
make_old_dir "infra-2446-fix" >/dev/null
# T11: fix-* pattern.
make_old_dir "fix-memory-leak" >/dev/null
# T12: *-rescue pattern.
make_old_dir "auth-rescue" >/dev/null
# T13: boring dir (no pattern match) — old.
make_old_dir "boring-random-dir" >/dev/null
# T14: fresh rescue-pattern dir — should be skipped.
make_fresh_dir "fix-fresh-test" >/dev/null

# ── Run reaper against fixture environment ────────────────────────────────────
# Key overrides:
#   CHUMP_REPO_ROOT_OVERRIDE   → redirects state.db / lock-dir lookups
#   CHUMP_RESCUE_SCAN_BASE     → rescue-pattern pass scans RESCUE_BASE instead of /tmp
#   WORKTREE_SCAN_PATHS        → tmp_chump pass scans our fixture chump-* dirs
#   CHUMP_REAPER_SAFETY_CHECK=0 → bypass lsof + heartbeat guards
#   ORPHAN_AGE_MIN_HOURS=12    → default threshold (fixtures are 15h old)

set +e
OUT=$(
    CHUMP_REPO_ROOT_OVERRIDE="$FAKE_REPO" \
    CHUMP_REAPER_SAFETY_CHECK=0 \
    CHUMP_SKIP_INSTRUMENTATION=1 \
    WORKTREE_SCAN_PATHS="$TMPBASE/chump-*" \
    CHUMP_RESCUE_SCAN_BASE="$RESCUE_BASE" \
    ORPHAN_AGE_MIN_HOURS=12 \
    bash "$REAPER" --dry-run --force-skip-process-check 2>&1
)
RC=$?
set -e

echo "--- reaper output (last 50 lines) ---"
echo "$OUT" | tail -50
echo "--- end output ---"

# T15: reaper exits 0.
if [[ $RC -eq 0 ]]; then
    ok "T15: reaper exited 0 in dry-run mode"
else
    fail "T15: reaper exited $RC (non-zero) in dry-run mode"
fi

# T8: chump-NN in WORKTREE_SCAN_PATHS considered.
if echo "$OUT" | grep -q "chump-9999"; then
    ok "T8: chump-NN candidate found in tmp_chump scan pass"
else
    fail "T8: chump-NN candidate NOT found — tmp_chump pass may be broken"
fi

# T9: ship-068 → rescue-pattern pass.
if echo "$OUT" | grep -q "ship-068"; then
    ok "T9: ship-068 standalone dir found by rescue-pattern pass"
else
    fail "T9: ship-068 NOT found — rescue-pattern pass broken for ship-NNN"
fi

# T10: infra-NNN-fix → rescue-pattern pass.
if echo "$OUT" | grep -q "infra-2446-fix"; then
    ok "T10: infra-NNN-fix standalone dir found by rescue-pattern pass"
else
    fail "T10: infra-2446-fix NOT found — rescue-pattern pass broken for infra-NNN-fix"
fi

# T11: fix-* → rescue-pattern pass.
if echo "$OUT" | grep -q "fix-memory-leak"; then
    ok "T11: fix-* standalone dir found by rescue-pattern pass"
else
    fail "T11: fix-memory-leak NOT found — rescue-pattern pass broken for fix-*"
fi

# T12: *-rescue → rescue-pattern pass.
if echo "$OUT" | grep -q "auth-rescue"; then
    ok "T12: *-rescue standalone dir found by rescue-pattern pass"
else
    fail "T12: auth-rescue NOT found — rescue-pattern pass broken for *-rescue"
fi

# T13: boring-random-dir → NOT flagged (no rescue pattern).
if echo "$OUT" | grep -q "boring-random-dir"; then
    fail "T13: boring-random-dir (no rescue pattern) was incorrectly included"
else
    ok "T13: boring-random-dir correctly excluded (no rescue pattern match)"
fi

# T14: fix-fresh-test → NOT flagged (too young).
# The enumerate function filters it before output; or it may appear with a
# too-young skip annotation. Either way it must NOT appear as a reapable candidate.
if echo "$OUT" | grep -qE "fix-fresh-test.*(reapable|REAPABLE|dry-run.*would)"; then
    fail "T14: fresh rescue-pattern dir incorrectly marked reapable"
else
    ok "T14: fresh rescue-pattern dir (fix-fresh-test) not marked reapable"
fi

# scan_source=rescue-pattern should appear in output since we have old rescue dirs.
if echo "$OUT" | grep -qE "rescue-pattern"; then
    ok "bonus: scan_source=rescue-pattern annotation visible in output"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== INFRA-2339 broad-scan results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
