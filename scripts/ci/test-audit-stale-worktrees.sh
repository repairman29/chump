#!/usr/bin/env bash
# test-audit-stale-worktrees.sh — ZERO-WASTE-001
#
# Tests scripts/ops/audit-stale-worktrees.sh:
#   1. Stale worktree with NO matching lease → reports reason=no_lease_ever_existed
#   2. Stale worktree with EXPIRED-heartbeat lease → reports reason=orphaned_lease
#   3. Fresh worktree (< threshold) → NOT reported
#   4. Stale worktree with FRESH lease (active worker) → NOT reported
#   5. kind=worktree_stale_detected emitted to ambient.jsonl with all required fields
#   6. Script is READ-ONLY — never deletes the worktree dirs
#   7. No --execute flag exists (audit is purely read-only)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT_SCRIPT="$REPO_ROOT/scripts/ops/audit-stale-worktrees.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$AUDIT_SCRIPT" ]] || fail "audit-stale-worktrees.sh not found at $AUDIT_SCRIPT"
[[ -x "$AUDIT_SCRIPT" ]] || fail "audit-stale-worktrees.sh is not executable"

TMP="$(mktemp -d -t test-audit-stale.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── AC #7: No --execute flag (must reject it) ────────────────────────────────
if bash "$AUDIT_SCRIPT" --execute 2>/dev/null; then
    fail "AC #7: --execute should not be accepted (audit is READ-ONLY)"
fi
pass "AC #7: --execute flag rejected (audit is READ-ONLY)"

# ── Set up a fake repo with .chump-locks and scan dir ────────────────────────
FAKE_REPO="$TMP/fake-repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.email "test@chump.bot"
git -C "$FAKE_REPO" config user.name "Test"
echo "init" > "$FAKE_REPO/README"
git -C "$FAKE_REPO" add README
git -C "$FAKE_REPO" commit -q -m "init"

FAKE_LOCKS="$FAKE_REPO/.chump-locks"
mkdir -p "$FAKE_LOCKS"
FAKE_AMBIENT="$FAKE_LOCKS/ambient.jsonl"
FAKE_SCAN="$TMP/scan"
mkdir -p "$FAKE_SCAN"

# Helper: make a worktree backdated to age_hours old.
make_backdated_worktree() {
    local name="$1" age_h="$2"
    local wt_path="$FAKE_SCAN/$name"
    local branch="chump/${name}"
    git -C "$FAKE_REPO" worktree add "$wt_path" -b "$branch" -q 2>/dev/null
    # Backdate the directory mtime portably. BSD `date -v` and GNU `date -d`
    # have incompatible syntax + `touch -t` parsing varied across the CI runner
    # vs local macOS — original 2026-05-15 PR #2097 failed on Linux because of
    # this. Python's os.utime is portable everywhere python3 is installed
    # (mandatory on Chump runners and dev machines).
    python3 -c "import os,time; t=time.time()-${age_h}*3600; os.utime('$wt_path',(t,t))" \
        2>/dev/null || true
    printf '%s\n' "$wt_path"
}

# Helper: write a lease JSON file for a worktree with a configurable
# heartbeat age (in hours back from now).
write_lease() {
    local name="$1" wt_path="$2" hb_age_h="$3"
    local hb
    # Portable ISO8601-N-hours-ago via Python (BSD date -v vs GNU date -d
    # incompatibility broke this on Linux CI in PR #2097's original test).
    hb="$(python3 -c "import time; print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time()-${hb_age_h}*3600)))" 2>/dev/null \
        || echo "1970-01-01T00:00:00Z")"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$FAKE_LOCKS/${name}.json" << LEASE
{
  "gap_id":"TEST-${name}",
  "session_id":"test-${name}",
  "worktree":"$wt_path",
  "branch":"chump/${name}",
  "taken_at":"$now",
  "heartbeat_at":"$hb"
}
LEASE
}

run_audit() {
    env -u GIT_DIR -u GIT_WORK_TREE \
        bash -c "cd '$FAKE_REPO' && bash '$AUDIT_SCRIPT' --age-hours 24 --scan-dir '$FAKE_SCAN' --json" \
        2>/dev/null || true
}

# ── Test 1: stale worktree, no lease → no_lease_ever_existed ─────────────────
WT1="$(make_backdated_worktree "no-lease-stale" 48)"
out1="$(run_audit)"

echo "$out1" | grep -q '"reason":"no_lease_ever_existed"' \
    || fail "Test 1: stale-no-lease worktree should produce reason=no_lease_ever_existed; got: $out1"
echo "$out1" | grep -q "$WT1" \
    || fail "Test 1: output should mention $WT1"
pass "Test 1: stale worktree with no lease → reason=no_lease_ever_existed"

# ── Test 2: stale worktree, expired lease → orphaned_lease ───────────────────
WT2="$(make_backdated_worktree "orphan-lease" 48)"
# Heartbeat 48h ago — well past the 24h threshold → orphaned.
write_lease "orphan-lease" "$WT2" 48
out2="$(run_audit)"

echo "$out2" | grep "$WT2" | grep -q '"reason":"orphaned_lease"' \
    || fail "Test 2: stale+expired-lease should be reason=orphaned_lease; got: $out2"
pass "Test 2: stale worktree with orphaned (>24h heartbeat) lease → reason=orphaned_lease"

# ── Test 3: fresh worktree (< threshold) → NOT reported ──────────────────────
WT3="$(make_backdated_worktree "fresh-wt" 1)"
out3="$(run_audit)"
if echo "$out3" | grep -q "$WT3"; then
    fail "Test 3: fresh worktree should NOT appear in audit output; got: $out3"
fi
pass "Test 3: fresh worktree (<24h) correctly NOT reported"

# ── Test 4: stale worktree with FRESH lease → NOT reported ───────────────────
WT4="$(make_backdated_worktree "fresh-lease" 48)"
# Heartbeat now → fresh; even though dir is 48h old, an active worker is here.
write_lease "fresh-lease" "$WT4" 0
out4="$(run_audit)"
if echo "$out4" | grep -q "$WT4"; then
    fail "Test 4: stale worktree with FRESH lease should NOT be reported; got: $out4"
fi
pass "Test 4: stale worktree with fresh-heartbeat lease NOT reported (active worker)"

# ── Test 5: ambient event emitted with required fields ───────────────────────
[[ -f "$FAKE_AMBIENT" ]] || fail "Test 5: ambient.jsonl should exist at $FAKE_AMBIENT"

grep -q '"kind":"worktree_stale_detected"' "$FAKE_AMBIENT" \
    || fail "Test 5: ambient.jsonl should contain kind=worktree_stale_detected"
grep '"kind":"worktree_stale_detected"' "$FAKE_AMBIENT" | grep -q '"age_hours"' \
    || fail "Test 5: event should contain age_hours field"
grep '"kind":"worktree_stale_detected"' "$FAKE_AMBIENT" | grep -q '"reason"' \
    || fail "Test 5: event should contain reason field"
grep '"kind":"worktree_stale_detected"' "$FAKE_AMBIENT" | grep -q '"worktree"' \
    || fail "Test 5: event should contain worktree (path) field"

# Both taxonomy reasons should be observable across the test run.
grep '"kind":"worktree_stale_detected"' "$FAKE_AMBIENT" | grep -q '"reason":"no_lease_ever_existed"' \
    || fail "Test 5: ambient should record reason=no_lease_ever_existed for Test 1"
grep '"kind":"worktree_stale_detected"' "$FAKE_AMBIENT" | grep -q '"reason":"orphaned_lease"' \
    || fail "Test 5: ambient should record reason=orphaned_lease for Test 2"
pass "Test 5: kind=worktree_stale_detected emitted with path/age_hours/reason fields"

# ── Test 6: script is READ-ONLY — worktrees still exist ──────────────────────
for wt in "$WT1" "$WT2" "$WT3" "$WT4"; do
    [[ -d "$wt" ]] || fail "Test 6: $wt was deleted — audit must be READ-ONLY!"
done
pass "Test 6: all worktrees still present after audit (READ-ONLY confirmed)"

# ── AC: registry entry present ───────────────────────────────────────────────
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q "kind: worktree_stale_detected" "$REG" \
    || fail "EVENT_REGISTRY.yaml missing kind: worktree_stale_detected"
pass "EVENT_REGISTRY.yaml contains worktree_stale_detected entry"

echo ""
echo "All ZERO-WASTE-001 audit checks passed (7/7)."
