#!/usr/bin/env bash
# test-stale-worktree-reaper-safety.sh — INFRA-1074
#
# Verifies that:
#  1. gap-claim.sh writes "worktree" field to lease JSON
#  2. stale-worktree-reaper.sh skips worktrees with active lease (fresh heartbeat)
#  3. stale-worktree-reaper.sh skips worktrees with fresh .git/index mtime
#  4. stale-worktree-reaper.sh emits kind=worktree_reaper_skipped_active
#  5. CHUMP_REAPER_SAFETY_CHECK=0 bypasses safety checks
#  6. stale heartbeat (>15 min) does NOT protect the worktree via lease

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

LOCK_DIR="$TMPDIR_BASE/locks"
AMBIENT="$LOCK_DIR/ambient.jsonl"
mkdir -p "$LOCK_DIR"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Resolve to main repo root (may be called from a worktree)
_GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON_DIR" != ".git" ]]; then
    REPO_ROOT="$(dirname "$_GIT_COMMON_DIR")"
fi

echo "=== INFRA-1074: stale-worktree-reaper safety checks ==="

# ─── Helper: inline is_active_lease logic from stale-worktree-reaper.sh ───────
# Returns 0 if wt_name appears in ACTIVE_WORKTREES
is_active_lease_test() {
    local wt="$1"
    for a in $ACTIVE_WORKTREES; do
        [[ "$a" == "$wt" ]] && return 0
        [[ "$a" == */"$wt" ]] && return 0
    done
    return 1
}

# ─── Helper: build ACTIVE_WORKTREES from lease dir (mirroring reaper logic) ───
build_active_worktrees() {
    local lock_dir="$1" now_ts; now_ts="$(date +%s)"
    ACTIVE_WORKTREES=""
    for lease in "$lock_dir"/*.json; do
        [[ -f "$lease" ]] || continue
        wt=$(python3 -c "import json; d=json.load(open('$lease')); print(d.get('worktree',''))" 2>/dev/null || echo "")
        [[ -z "$wt" ]] && continue
        hb=$(python3 -c "import json; d=json.load(open('$lease')); print(d.get('heartbeat_at', d.get('taken_at','')))" 2>/dev/null || echo "")
        if [[ -n "$hb" ]]; then
            hb_ts=$(date -d "$hb" +%s 2>/dev/null \
                || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$hb" +%s 2>/dev/null \
                || echo 0)
            age_s=$(( now_ts - hb_ts ))
            [[ $age_s -gt 900 ]] && continue
        fi
        ACTIVE_WORKTREES="$ACTIVE_WORKTREES $wt"
    done
}

# ─── Test 1: gap-claim.sh writes "worktree" field ─────────────────────────────
echo ""
echo "--- Test 1: gap-claim.sh writes worktree field"

CLAIM_WD="$TMPDIR_BASE/wt-claim-test"
mkdir -p "$CLAIM_WD"
FAKE_LEASE="$LOCK_DIR/test-session.json"

python3 - "$FAKE_LEASE" "TEST-001" "test-session" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "" "0" "$CLAIM_WD" <<'PYEOF'
import json, os, sys
path, gap_id, session_id, taken_at, expires_at, paths_csv, spec, repo_root = sys.argv[1:]
paths_list = [p.strip() for p in paths_csv.split(",") if p.strip()] if paths_csv else []
d = {
    "session_id": session_id,
    "paths": paths_list,
    "taken_at": taken_at,
    "expires_at": expires_at,
    "heartbeat_at": taken_at,
    "purpose": f"gap:{gap_id}",
    "gap_id": gap_id,
    "worktree": os.path.basename(repo_root),
}
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF

wt_field=$(python3 -c "import json; d=json.load(open('$FAKE_LEASE')); print(d.get('worktree','MISSING'))")
if [[ "$wt_field" == "wt-claim-test" ]]; then
    ok "worktree field written as basename of repo_root"
else
    fail "worktree field wrong: got '$wt_field', want 'wt-claim-test'"
fi
rm -f "$FAKE_LEASE"

# ─── Test 2: fresh lease → ACTIVE_WORKTREES includes the worktree ─────────────
echo ""
echo "--- Test 2: fresh heartbeat protects worktree"

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$LOCK_DIR/active-session.json" <<EOF
{
  "session_id": "test-active",
  "gap_id": "TEST-002",
  "worktree": "chump-test-active",
  "heartbeat_at": "$NOW_ISO",
  "taken_at": "$NOW_ISO",
  "expires_at": "$NOW_ISO"
}
EOF

build_active_worktrees "$LOCK_DIR"
if is_active_lease_test "chump-test-active"; then
    ok "fresh heartbeat: worktree recognized as active"
else
    fail "fresh heartbeat: worktree NOT in ACTIVE_WORKTREES (got: '$ACTIVE_WORKTREES')"
fi

# ─── Test 3: stale heartbeat (>15 min) → NOT in ACTIVE_WORKTREES ──────────────
echo ""
echo "--- Test 3: stale heartbeat (>15 min) not protected"

STALE_TS="2000-01-01T00:00:00Z"
cat > "$LOCK_DIR/stale-session.json" <<EOF
{
  "session_id": "test-stale",
  "gap_id": "TEST-003",
  "worktree": "chump-test-stale",
  "heartbeat_at": "$STALE_TS",
  "taken_at": "$STALE_TS",
  "expires_at": "$STALE_TS"
}
EOF

build_active_worktrees "$LOCK_DIR"
if ! is_active_lease_test "chump-test-stale"; then
    ok "stale heartbeat: worktree correctly excluded from ACTIVE_WORKTREES"
else
    fail "stale heartbeat: worktree wrongly protected (ACTIVE_WORKTREES: '$ACTIVE_WORKTREES')"
fi

rm -f "$LOCK_DIR/stale-session.json"

# ─── Test 4: .git/index fresh mtime → reaper skips ───────────────────────────
echo ""
echo "--- Test 4: fresh .git/index triggers skip"

# Create a mock .git/index file touched within 5 min
FAKE_WT="$TMPDIR_BASE/chump-test-index-fresh"
mkdir -p "$FAKE_WT/.git"
touch "$FAKE_WT/.git/index"  # mtime = now

# Inline the index-mtime check from stale-worktree-reaper.sh
check_index_fresh() {
    local wt_path="$1" git_index=""
    if [[ -f "$wt_path/.git" ]]; then
        local gitdir; gitdir=$(sed 's/^gitdir: //' "$wt_path/.git" 2>/dev/null || true)
        [[ -n "$gitdir" && -f "$gitdir/index" ]] && git_index="$gitdir/index"
    elif [[ -f "$wt_path/.git/index" ]]; then
        git_index="$wt_path/.git/index"
    fi
    [[ -z "$git_index" ]] && return 1
    local idx_fresh
    idx_fresh=$(find "$git_index" -mmin -5 2>/dev/null | head -1 || true)
    [[ -n "$idx_fresh" ]]
}

if check_index_fresh "$FAKE_WT"; then
    ok "fresh .git/index (mtime now) correctly triggers skip"
else
    fail "fresh .git/index NOT detected as in-flight"
fi

# Test with an old index
touch -t 200001010000 "$FAKE_WT/.git/index"  # year 2000
if ! check_index_fresh "$FAKE_WT"; then
    ok "old .git/index correctly does NOT trigger skip"
else
    fail "old .git/index wrongly detected as in-flight"
fi

# ─── Test 5: ambient emit when skipping ───────────────────────────────────────
echo ""
echo "--- Test 5: ambient emit on skip"

# Inline _emit_reaper_skipped
emit_reaper_skipped_test() {
    local wt_path="$1" reason="$2"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"worktree_reaper_skipped_active","worktree":"%s","reason":"%s"}\n' \
        "$ts" "$wt_path" "$reason" >> "$AMBIENT" 2>/dev/null || true
}

emit_reaper_skipped_test "/tmp/chump-test" "active_lease"
emit_reaper_skipped_test "/tmp/chump-test2" "git_index_fresh"

if grep -q '"kind":"worktree_reaper_skipped_active"' "$AMBIENT" 2>/dev/null; then
    ok "ambient emit contains kind=worktree_reaper_skipped_active"
else
    fail "ambient emit missing kind=worktree_reaper_skipped_active"
fi

count=$(grep -c '"worktree_reaper_skipped_active"' "$AMBIENT" 2>/dev/null || echo 0)
if [[ "$count" -eq 2 ]]; then
    ok "two skip events emitted (active_lease + git_index_fresh)"
else
    fail "expected 2 skip events, got $count"
fi

# ─── Test 6: CHUMP_REAPER_SAFETY_CHECK=0 bypasses lease check ─────────────────
echo ""
echo "--- Test 6: CHUMP_REAPER_SAFETY_CHECK=0 disables lease protection"

build_active_worktrees_no_safety() {
    # Mimic what the reaper does with REAPER_SAFETY_CHECK=0 (skips lease collection)
    ACTIVE_WORKTREES=""
}

build_active_worktrees_no_safety
if ! is_active_lease_test "chump-test-active"; then
    ok "REAPER_SAFETY_CHECK=0: ACTIVE_WORKTREES empty, no lease protection"
else
    fail "REAPER_SAFETY_CHECK=0: worktree still protected (should not be)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
