#!/usr/bin/env bash
# test-worktree-iter-lib.sh — INFRA-1211
#
# Exercises scripts/lib/worktree-iter.sh: verifies each exported function
# works correctly against synthetic fixtures and that all 5 refactored
# reapers source the lib.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/worktree-iter.sh"

echo "=== INFRA-1211 worktree-iter lib tests ==="

# ── (a) Library exists and is sourceable ─────────────────────────────────────
if [[ -f "$LIB" ]]; then
    ok "worktree-iter.sh exists"
else
    fail "worktree-iter.sh missing at $LIB"
    exit 1
fi

# Source it — also sources lease.sh transitively if needed.
# shellcheck source=../lib/worktree-iter.sh
source "$LIB"
ok "worktree-iter.sh sourceable without error"

# ── (b) scan_worktrees yields synthetic dirs ──────────────────────────────────
TMP="$(mktemp -d -t worktree-iter-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Create two fake worktree dirs under a synthetic .claude/worktrees/
FAKE_WT_BASE="$TMP/.claude/worktrees"
mkdir -p "$FAKE_WT_BASE/wt-alpha"
mkdir -p "$FAKE_WT_BASE/wt-beta"

out="$(CHUMP_WORKTREE_BASE="$FAKE_WT_BASE" CHUMP_WT_SCAN_TMP=0 scan_worktrees)"
count=$(echo "$out" | grep -c "wt-" 2>/dev/null || echo 0)
if [[ "$count" -ge 2 ]]; then
    ok "scan_worktrees yields worktree dirs from CHUMP_WORKTREE_BASE"
else
    fail "scan_worktrees missing dirs (got $count, want >=2)"
fi

# ── (c) scan_worktrees --no-tmp excludes /tmp/chump-* ─────────────────────────
# This is hard to test without creating actual /tmp dirs; test that the flag
# doesn't error and returns only managed dirs.
out2="$(CHUMP_WORKTREE_BASE="$FAKE_WT_BASE" scan_worktrees --no-tmp 2>&1)"
if echo "$out2" | grep -q "wt-alpha"; then
    ok "scan_worktrees --no-tmp includes managed dirs"
else
    fail "scan_worktrees --no-tmp missing managed dirs"
fi

# ── (d) wt_has_active_lease: no lease → return 1 ─────────────────────────────
FAKE_LOCKS="$TMP/.chump-locks"
mkdir -p "$FAKE_LOCKS"
CHUMP_LOCK_DIR="$FAKE_LOCKS" REAPER_REPO_ROOT="$TMP" \
    wt_has_active_lease "$FAKE_WT_BASE/wt-alpha" 900 \
    && fail "wt_has_active_lease returned 0 with no leases" \
    || ok "wt_has_active_lease returns 1 when no leases present"

# ── (e) wt_has_active_lease: stale lease → return 1 ──────────────────────────
STALE_TS="2000-01-01T00:00:00Z"
cat > "$FAKE_LOCKS/claim-stale.json" <<EOF
{
  "gap_id": "TEST-001",
  "worktree": "$FAKE_WT_BASE/wt-alpha",
  "heartbeat_at": "$STALE_TS",
  "expires_at": "2000-01-02T00:00:00Z"
}
EOF
CHUMP_LOCK_DIR="$FAKE_LOCKS" REAPER_REPO_ROOT="$TMP" \
    wt_has_active_lease "$FAKE_WT_BASE/wt-alpha" 900 \
    && fail "wt_has_active_lease returned 0 for stale lease" \
    || ok "wt_has_active_lease returns 1 for stale (2000) heartbeat"

# ── (f) wt_has_active_lease: fresh lease → return 0 ──────────────────────────
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$FAKE_LOCKS/claim-fresh.json" <<EOF
{
  "gap_id": "TEST-002",
  "worktree": "$FAKE_WT_BASE/wt-beta",
  "heartbeat_at": "$NOW_TS",
  "expires_at": "2099-01-01T00:00:00Z"
}
EOF
CHUMP_LOCK_DIR="$FAKE_LOCKS" REAPER_REPO_ROOT="$TMP" \
    wt_has_active_lease "$FAKE_WT_BASE/wt-beta" 900 \
    && ok "wt_has_active_lease returns 0 for fresh heartbeat" \
    || fail "wt_has_active_lease returned 1 for fresh lease"

# ── (g) wt_is_dirty: empty dir → 1 (not a git repo; treated as clean) ─────────
mkdir -p "$TMP/clean-wt"
wt_is_dirty "$TMP/clean-wt" \
    && fail "wt_is_dirty returned 0 for empty non-git dir" \
    || ok "wt_is_dirty returns 1 for non-git dir (safe default)"

# ── (h) emit_reaper_event writes valid JSON to ambient.jsonl ─────────────────
AMBIENT="$FAKE_LOCKS/ambient.jsonl"
CHUMP_AMBIENT_LOG="$AMBIENT" REAPER_NAME="test-reaper" REAPER_REPO_ROOT="$TMP" \
    emit_reaper_event "worktree_reaper_skipped_active" "/tmp/wt-test" "test_reason"

if [[ -f "$AMBIENT" ]]; then
    python3 -c "import json; json.loads(open('$AMBIENT').read().strip())" \
        && ok "emit_reaper_event writes valid JSON to ambient.jsonl" \
        || fail "emit_reaper_event produced invalid JSON"
    if grep -q '"kind":"worktree_reaper_skipped_active"' "$AMBIENT"; then
        ok "emit_reaper_event includes correct kind field"
    else
        fail "emit_reaper_event missing kind field"
    fi
    if grep -q '"reaper":"test-reaper"' "$AMBIENT"; then
        ok "emit_reaper_event includes REAPER_NAME"
    else
        fail "emit_reaper_event missing reaper field"
    fi
else
    fail "emit_reaper_event did not create ambient.jsonl"
fi

# ── (i) All refactored reapers source worktree-iter.sh ───────────────────────
reapers=(
    "scripts/ops/active-target-reaper.sh"
    "scripts/ops/stale-worktree-reaper.sh"
    "scripts/ops/prune-worktrees.sh"
    "scripts/ops/queue-health-monitor.sh"
    "scripts/coord/worktree-prune.sh"
    "scripts/coord/branch-reaper.sh"
)
for r in "${reapers[@]}"; do
    path="$REPO_ROOT/$r"
    if [[ -f "$path" ]]; then
        if grep -q "worktree-iter.sh" "$path"; then
            ok "$r sources worktree-iter.sh"
        else
            fail "$r does NOT source worktree-iter.sh"
        fi
    else
        fail "$r not found"
    fi
done

# ── (j) No reaper defines its own worktree scanning loop ─────────────────────
# Check that none of the refactored reapers have the old inline
# _emit_reaper_skipped() function definition (replaced by emit_reaper_event).
for r in "${reapers[@]}"; do
    path="$REPO_ROOT/$r"
    [[ -f "$path" ]] || continue
    # stale-worktree-reaper.sh keeps thin wrappers — that's allowed.
    if [[ "$r" == *"stale-worktree"* ]]; then
        continue
    fi
    if grep -q "^_emit_reaper_skipped()" "$path" 2>/dev/null; then
        fail "$r still defines its own _emit_reaper_skipped() — not migrated"
    else
        ok "$r has no inline _emit_reaper_skipped() definition"
    fi
done

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
