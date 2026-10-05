#!/usr/bin/env bash
# scripts/ci/test-shared-target-cache-reaper.sh — RESILIENT-1045
#
# Proves the proactive shared-target-cache-reaper:
#   1. Under-cap target        → no-op, dir untouched, nothing emitted
#   2. Over-cap, HOT           → skipped, emits reap_skipped_hot, dir intact
#   3. Over-cap, idle, DRY-RUN → emits dryrun event, dir untouched
#   4. Over-cap, idle, EXECUTE → dir actually deleted, emits reaped event
#   5. disk-pressure-reaper.sh wires this reaper in unconditionally (even on
#      the ≥50GB early-exit path) so the cache is capped proactively, not
#      only during a tier-4 disk emergency.
#
# No real 50GB dir: size + hotness are injected via
# CHUMP_SHARED_TARGET_GB_OVERRIDE / CHUMP_SHARED_TARGET_HOT_OVERRIDE.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
REAPER="$REPO_ROOT/scripts/coord/shared-target-cache-reaper.sh"
PRESSURE="$REPO_ROOT/scripts/coord/disk-pressure-reaper.sh"
fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

[[ -x "$REAPER" ]] || { echo "reaper not executable: $REAPER" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
AMB="$WORK/ambient.jsonl"; : > "$AMB"
FAKE_TARGET="$WORK/faketarget"; mkdir -p "$FAKE_TARGET"; echo x > "$FAKE_TARGET/marker"

base_env() {
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_SHARED_TARGET="$FAKE_TARGET" \
  CHUMP_SHARED_TARGET_CAP_GB=50 \
  "$@"
}

echo "== 1. under cap → no-op, no emit, dir intact =="
: > "$AMB"
CHUMP_SHARED_TARGET_GB_OVERRIDE=10 CHUMP_SHARED_TARGET_HOT_OVERRIDE=0 base_env bash "$REAPER" >/dev/null 2>&1
rc=$?
(( rc == 0 )) && pass "under-cap exits 0" || fail "under-cap should exit 0, got $rc"
grep -q 'shared_target_cache' "$AMB" && fail "under-cap must not emit any reap event" || pass "no reap event under cap"
[[ -f "$FAKE_TARGET/marker" ]] && pass "target dir untouched" || fail "target dir was modified under cap"

echo "== 2. over cap, HOT → skipped, dir intact =="
: > "$AMB"
CHUMP_SHARED_TARGET_GB_OVERRIDE=150 CHUMP_SHARED_TARGET_HOT_OVERRIDE=1 base_env bash "$REAPER" --execute >/dev/null 2>&1
rc=$?
(( rc == 0 )) && pass "over-cap hot exits 0" || fail "over-cap hot should exit 0, got $rc"
grep -q '"kind":"shared_target_cache_reap_skipped_hot"' "$AMB" && pass "emitted skipped_hot event" || fail "missing skipped_hot event"
[[ -f "$FAKE_TARGET/marker" ]] && pass "HOT guard prevented delete (even with --execute)" || fail "HOT dir was deleted — hard guard broken"

echo "== 3. over cap, idle, DRY-RUN → emits dryrun, dir intact =="
: > "$AMB"
CHUMP_SHARED_TARGET_GB_OVERRIDE=150 CHUMP_SHARED_TARGET_HOT_OVERRIDE=0 base_env bash "$REAPER" >/dev/null 2>&1
rc=$?
(( rc == 0 )) && pass "over-cap idle dry-run exits 0" || fail "over-cap idle dry-run should exit 0, got $rc"
grep -q '"kind":"shared_target_cache_reap_dryrun"' "$AMB" && pass "emitted dryrun event" || fail "missing dryrun event"
grep -q '"target_gb":150' "$AMB" && pass "reported target size" || fail "size not reported"
[[ -f "$FAKE_TARGET/marker" ]] && pass "DRY-RUN did NOT delete the target" || fail "DRY-RUN deleted the target (must never happen)"

echo "== 4. over cap, idle, EXECUTE → dir actually reaped =="
: > "$AMB"
CHUMP_SHARED_TARGET_GB_OVERRIDE=150 CHUMP_SHARED_TARGET_HOT_OVERRIDE=0 base_env bash "$REAPER" --execute >/dev/null 2>&1
rc=$?
(( rc == 0 )) && pass "over-cap idle execute exits 0" || fail "over-cap idle execute should exit 0, got $rc"
grep -q '"kind":"shared_target_cache_reaped"' "$AMB" && pass "emitted reaped event" || fail "missing reaped event"
[[ -d "$FAKE_TARGET" ]] && fail "target dir should be gone after execute reap" || pass "target dir actually removed"

echo "== 5. disk-pressure-reaper.sh wires the reaper in unconditionally =="
grep -q 'shared-target-cache-reaper.sh' "$PRESSURE" || fail "disk-pressure-reaper.sh does not invoke shared-target-cache-reaper.sh"
pass "disk-pressure-reaper.sh references shared-target-cache-reaper.sh"
# Must be called BEFORE the ≥50GB early-exit, so it runs even when overall
# disk has plenty of headroom (the exact gap this gap closes).
reaper_call_line=$(grep -n 'SHARED_TARGET_REAPER"' "$PRESSURE" | tail -1 | cut -d: -f1)
early_exit_line=$(grep -n 'idle (≥ 50GB threshold)' "$PRESSURE" | head -1 | cut -d: -f1)
if [[ -n "$reaper_call_line" && -n "$early_exit_line" ]] && (( reaper_call_line < early_exit_line )); then
  pass "shared-target reap runs before the ≥50GB early-exit (proactive, not tier-gated)"
else
  fail "shared-target reap must run before the ≥50GB early-exit (call=$reaper_call_line exit=$early_exit_line)"
fi

echo ""
if (( fails == 0 )); then echo "PASS test-shared-target-cache-reaper"; exit 0
else echo "FAIL ($fails) test-shared-target-cache-reaper"; exit 1; fi
