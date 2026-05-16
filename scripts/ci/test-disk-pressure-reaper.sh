#!/usr/bin/env bash
# scripts/ci/test-disk-pressure-reaper.sh — INFRA-1471

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/disk-pressure-reaper.sh"
PLIST="$REPO_ROOT/scripts/plists/dev.chump.disk-pressure-reaper.plist"
INSTALL="$REPO_ROOT/scripts/setup/install-disk-pressure-reaper-launchd.sh"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$SCRIPT" ]  || fail "disk-pressure-reaper.sh missing/not executable"
[ -f "$PLIST" ]   || fail "plist missing"
[ -x "$INSTALL" ] || fail "installer missing/not executable"
ok "all three files exist + executable"

# Default dry-run safety
grep -q 'DRY_RUN=1' "$SCRIPT" || fail "reaper must default to dry-run"
ok "defaults to dry-run"

# Four tiers documented
for tier in "Tier 1" "Tier 2" "Tier 3" "Tier 4"; do
  grep -q "$tier" "$SCRIPT" || fail "missing $tier in script"
done
ok "all 4 pressure tiers documented in script"

# Tier-specific thresholds
grep -q "free_gb.*ge 50" "$SCRIPT" || fail "≥50GB idle threshold missing"
grep -q "free_gb.*ge 20" "$SCRIPT" || fail "20GB tier-1 threshold missing"
grep -q "free_gb.*ge 10" "$SCRIPT" || fail "10GB tier-2 threshold missing"
grep -q "free_gb.*ge 5"  "$SCRIPT" || fail "5GB tier-3 threshold missing"
ok "all 4 tier thresholds present (50/20/10/5 GB)"

# Tier 2 — checks remote branch existence (merged+deleted heuristic)
grep -q "git.*ls-remote" "$SCRIPT" || fail "tier 2 must check remote branch exists"
ok "tier 2 honors merged-and-deleted branch heuristic"

# Tier 3 — checks active leases
grep -q "active_gaps" "$SCRIPT" || fail "tier 3 must build active-lease set"
grep -q "status --porcelain" "$SCRIPT" || fail "must check uncommitted before reap"
ok "tier 3 safety: active-lease + uncommitted-check"

# Tier 4 — emits ambient ALERT
grep -q "disk_pressure_red" "$SCRIPT" || fail "tier 4 must emit kind=disk_pressure_red"
grep -q "alert.*tier 4" "$SCRIPT" || fail "tier 4 must alert operator"
ok "tier 4 emits ambient ALERT + operator escalation hint"

# Plist
grep -q "dev.chump.disk-pressure-reaper" "$PLIST" || fail "plist label wrong"
grep -q "<integer>900</integer>" "$PLIST" || fail "plist StartInterval should be 900s (15 min)"
ok "plist: 15 min cadence"

# Force-tier override exists
grep -q "TIER_OVERRIDE" "$SCRIPT" || fail "--tier override missing"
ok "--tier override for manual testing"

# Run dry-run; should complete cleanly regardless of disk state
out=$("$SCRIPT" 2>&1)
echo "$out" | grep -qE "(disk free|tier|idle)" || fail "dry-run did not produce expected status output (got: $out)"
ok "dry-run executes cleanly"

echo
echo "All INFRA-1471 disk-pressure-reaper tests passed."
