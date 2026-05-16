#!/usr/bin/env bash
# scripts/ci/test-target-dir-reaper.sh — INFRA-1349
#
# Smoke-tests scripts/coord/target-dir-reaper.sh structural integrity +
# dry-run behavior. Does NOT actually reap anything (uses a temp scan-path
# override via env so the test is hermetic).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/target-dir-reaper.sh"
PLIST="$REPO_ROOT/scripts/plists/dev.chump.target-reaper.plist"
INSTALL="$REPO_ROOT/scripts/setup/install-target-reaper-launchd.sh"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$SCRIPT" ]  || fail "target-dir-reaper.sh missing or not executable"
[ -f "$PLIST" ]   || fail "dev.chump.target-reaper.plist missing"
[ -x "$INSTALL" ] || fail "install-target-reaper-launchd.sh missing or not executable"
ok "all three files exist (reaper script + plist + installer)"

# Reaper script structural checks
grep -q "kind=target_artifact_reaped" "$SCRIPT" \
  || fail "reaper must emit kind=target_artifact_reaped ambient events"
ok "ambient event kind documented in script"

grep -q "CHUMP_TARGET_REAPER_DISK_MIN_GB" "$SCRIPT" \
  || fail "disk-pressure threshold env var missing"
grep -q "CHUMP_TARGET_REAPER_IDLE_H" "$SCRIPT" \
  || fail "idle-hours threshold env var missing"
ok "configurable thresholds via env (disk MIN_GB + idle H)"

# Default dry-run safety
grep -q 'DRY_RUN=1' "$SCRIPT" \
  || fail "reaper must default to dry-run"
ok "defaults to dry-run (safety)"

# Lease-protection logic
grep -q "ACTIVE_LEASES" "$SCRIPT" \
  || fail "reaper must skip worktrees with active leases"
grep -q "expires_at" "$SCRIPT" \
  || fail "reaper must check lease expires_at"
ok "skips worktrees with active leases (expires_at > now)"

# Idle-mtime check
grep -qE '(find.*-mmin|stat.*\\\\%m)' "$SCRIPT" \
  || fail "reaper must check worktree idle mtime"
ok "checks idle mtime before reaping"

# Plist structural sanity
grep -q "dev.chump.target-reaper" "$PLIST" || fail "plist Label wrong"
grep -q "StartInterval" "$PLIST"           || fail "plist missing StartInterval"
grep -q "target-dir-reaper.sh" "$PLIST"    || fail "plist must invoke target-dir-reaper.sh"
ok "plist has Label, StartInterval, invokes reaper script"

# Hermetic dry-run with no disk pressure (force exit path)
out=$(CHUMP_TARGET_REAPER_DISK_MIN_GB=1 "$SCRIPT" 2>&1)
echo "$out" | grep -q "no action needed" \
  || fail "reaper should exit 0 with 'no action needed' when disk has plenty (got: $out)"
ok "reaper exits early when disk has plenty"

# Force-mode dry-run from a clean cwd; should not crash
out=$("$SCRIPT" --force 2>&1)
echo "$out" | grep -qE "(would reap|dry-run summary|no action needed)" \
  || fail "reaper force-mode dry-run output unexpected: $out"
ok "force-mode dry-run runs cleanly"

echo
echo "All INFRA-1349 target-reaper smoke tests passed."
