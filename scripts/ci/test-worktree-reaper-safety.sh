#!/usr/bin/env bash
# test-worktree-reaper-safety.sh — INFRA-1074
#
# The worktree / cargo-target reapers must NEVER delete an actively-in-use
# worktree (fresh lease heartbeat / git index / uncommitted / unpushed work),
# even in critical mode. This verifies the shared guard lib
# (scripts/coord/lib/worktree-reaper-safety.sh) and that target-dir-reaper.sh
# honors it under --critical.
set -uo pipefail

PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
fail(){ FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$1"; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/worktree-reaper-safety.sh"
REAPER="$REPO_ROOT/scripts/coord/target-dir-reaper.sh"
[ -f "$LIB" ] || { echo "lib missing: $LIB"; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE_REPO="$TMP/repo"; mkdir -p "$FAKE_REPO/.chump-locks"

git_init(){ mkdir -p "$1"; git -C "$1" init -q; git -C "$1" config user.email t@t.t; git -C "$1" config user.name t; }
commit_one(){ echo x > "$1/file"; printf 'target/\n' > "$1/.gitignore"; git -C "$1" add file .gitignore; git -C "$1" commit -qm init; }
age_index(){ local i; i="$(git -C "$1" rev-parse --git-path index)"; case "$i" in /*) : ;; *) i="$1/$i" ;; esac; touch -t 202001010000 "$i" 2>/dev/null; }

# ── 1. fresh lease referencing the worktree → ACTIVE ─────────────────────────
WT_LEASE="$TMP/chump-lease"; git_init "$WT_LEASE"; commit_one "$WT_LEASE"; age_index "$WT_LEASE"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"worktree":"%s","heartbeat_at":"%s","expires_at":"2099-01-01T00:00:00Z"}\n' \
  "$WT_LEASE" "$now_iso" > "$FAKE_REPO/.chump-locks/claim-lease-123.json"
if worktree_is_active "$WT_LEASE" "$FAKE_REPO"; then pass "fresh lease → active"; else fail "fresh lease NOT protected"; fi

# ── 2. uncommitted changes → ACTIVE ──────────────────────────────────────────
WT_UNCO="$TMP/chump-unco"; git_init "$WT_UNCO"; commit_one "$WT_UNCO"; age_index "$WT_UNCO"; echo dirty > "$WT_UNCO/file"
if worktree_is_active "$WT_UNCO" "$FAKE_REPO"; then pass "uncommitted → active"; else fail "uncommitted NOT protected"; fi

# ── 3. unpushed work (committed, no remote) → ACTIVE ─────────────────────────
WT_UNPUSH="$TMP/chump-unpush"; git_init "$WT_UNPUSH"; commit_one "$WT_UNPUSH"; age_index "$WT_UNPUSH"
if worktree_is_active "$WT_UNPUSH" "$FAKE_REPO"; then pass "unpushed (HEAD on no remote) → active"; else fail "unpushed NOT protected"; fi

# ── 4. clean + pushed + old index + no lease → REAPABLE ──────────────────────
BARE="$TMP/remote.git"; git init -q --bare "$BARE"
WT_CLEAN="$TMP/chump-clean"; git clone -q "$BARE" "$WT_CLEAN" 2>/dev/null
git -C "$WT_CLEAN" config user.email t@t.t; git -C "$WT_CLEAN" config user.name t
commit_one "$WT_CLEAN"; git -C "$WT_CLEAN" push -q origin HEAD 2>/dev/null; age_index "$WT_CLEAN"
if worktree_is_active "$WT_CLEAN" "$FAKE_REPO"; then fail "clean+pushed wrongly protected"; else pass "clean+pushed+old-index → reapable"; fi

# ── 5. CHUMP_REAPER_SAFETY_CHECK=0 bypass → REAPABLE regardless ───────────────
if CHUMP_REAPER_SAFETY_CHECK=0 worktree_is_active "$WT_LEASE" "$FAKE_REPO"; then fail "bypass not honored"; else pass "CHUMP_REAPER_SAFETY_CHECK=0 → reapable"; fi

# ── 6. INTEGRATION: target-dir-reaper --critical spares active, reaps clean ───
SCANDIR="$TMP/scan"; mkdir -p "$SCANDIR"
WT_A="$SCANDIR/chump-active"; git_init "$WT_A"; commit_one "$WT_A"; echo dirty > "$WT_A/file"
mkdir -p "$WT_A/target"; echo bin > "$WT_A/target/artifact"
WT_C="$SCANDIR/chump-done"; git clone -q "$BARE" "$WT_C" 2>/dev/null
git -C "$WT_C" config user.email t@t.t; git -C "$WT_C" config user.name t
mkdir -p "$WT_C/target"; echo bin > "$WT_C/target/artifact"; age_index "$WT_C"
CHUMP_REPO="$FAKE_REPO" CHUMP_TARGET_REAPER_SCAN_GLOB="$SCANDIR/chump-*" \
  bash "$REAPER" --execute --force --critical >/dev/null 2>&1
if [ -d "$WT_A/target" ]; then pass "INTEGRATION: active worktree target/ survived --critical reaper"; else fail "active worktree target/ was REAPED (the INFRA-1074 bug)"; fi
if [ ! -d "$WT_C/target" ]; then pass "INTEGRATION: clean worktree target/ reaped (disk still reclaimed)"; else fail "clean worktree target/ NOT reaped (over-protective)"; fi

# ── 7. worktree_reaper_skipped_active emitted on protect ─────────────────────
if grep -q '"kind":"worktree_reaper_skipped_active"' "$FAKE_REPO/.chump-locks/ambient.jsonl" 2>/dev/null; then
  pass "emits kind=worktree_reaper_skipped_active for audit"
else
  fail "no worktree_reaper_skipped_active event emitted"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
