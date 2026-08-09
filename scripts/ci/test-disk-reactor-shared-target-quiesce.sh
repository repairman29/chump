#!/usr/bin/env bash
# test-disk-reactor-shared-target-quiesce.sh — RESILIENT-273
#
# Proves the disk-critical-reactor's terminal self-heal (quiesce_and_reclaim):
#   1. Under-cap target      → no-op (returns 1, nothing emitted, dir untouched)
#   2. Over-cap, DRY-RUN     → emits disk_reactor_quiesce_dryrun, dir UNTOUCHED
#   3. Over-cap, would-arm   → the DRY-RUN default is what protects prod; we assert
#      the execute path is gated behind the explicit env flag (not exercised live
#      here — it tears down daemons/deletes; that's validated by the guard test).
#   4. Hard guard shape: the delete only runs after a build-quiescence wait.
#
# No real 50GB dir and no real daemon/disk mutation: size is injected via
# CHUMP_SHARED_TARGET_GB_OVERRIDE and execute stays OFF (dry-run default).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REACTOR="$REPO_ROOT/scripts/coord/disk-critical-reactor.sh"
fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

[[ -x "$REACTOR" ]] || { echo "reactor not executable: $REACTOR" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
AMB="$WORK/ambient.jsonl"; : > "$AMB"
FAKE_TARGET="$WORK/faketarget"; mkdir -p "$FAKE_TARGET"; echo x > "$FAKE_TARGET/marker"

base_env() {
  CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_SHARED_TARGET="$FAKE_TARGET" \
  CHUMP_SHARED_TARGET_CAP_GB=50 \
  CHUMP_DISK_REACTOR_QUIESCE_EXECUTE=0 \
  "$@"
}

echo "== 1. under cap → no-op, no emit, dir intact =="
: > "$AMB"
CHUMP_SHARED_TARGET_GB_OVERRIDE=10 base_env bash "$REACTOR" --quiesce-check >/dev/null 2>&1
rc=$?
(( rc == 1 )) && pass "under-cap returns 1 (not applicable)" || fail "under-cap should return 1, got $rc"
grep -q 'disk_reactor_quiesce' "$AMB" && fail "under-cap must not emit a quiesce event" || pass "no quiesce event under cap"
[[ -f "$FAKE_TARGET/marker" ]] && pass "target dir untouched" || fail "target dir was modified under cap"

echo "== 2. over cap, DRY-RUN → emits dryrun, dir intact =="
: > "$AMB"
CHUMP_SHARED_TARGET_GB_OVERRIDE=150 base_env bash "$REACTOR" --quiesce-check >/dev/null 2>&1
rc=$?
(( rc == 0 )) && pass "over-cap dry-run returns 0" || fail "over-cap dry-run should return 0, got $rc"
grep -q '"kind":"disk_reactor_quiesce_dryrun"' "$AMB" && pass "emitted disk_reactor_quiesce_dryrun" || fail "missing dryrun event"
grep -q '"target_gb":150' "$AMB" && pass "reported target size" || fail "size not reported"
[[ -f "$FAKE_TARGET/marker" ]] && pass "DRY-RUN did NOT delete the target" || fail "DRY-RUN deleted the target (must never happen)"
grep -q 'disk_reactor_quiesce_started' "$AMB" && fail "dry-run must not start the execute path" || pass "execute path not entered in dry-run"

echo "== 3. execute is gated behind the explicit env flag =="
# Assert the script only enters the execute path when the flag is exactly 1.
grep -q 'QUIESCE_EXECUTE="\${CHUMP_DISK_REACTOR_QUIESCE_EXECUTE:-0}"' "$REACTOR" \
  && pass "execute defaults OFF (0)" || fail "execute must default to 0 (dry-run)"
grep -q 'if \[\[ "\$QUIESCE_EXECUTE" != "1" \]\]; then' "$REACTOR" \
  && pass "execute requires flag == 1" || fail "execute gate not exact-match on 1"

echo "== 4. hard quiescence guard exists before any delete =="
# The rm must be preceded by the not-quiescent abort guard in source order.
guard_line=$(grep -n 'not_quiescent' "$REACTOR" | head -1 | cut -d: -f1)
rm_line=$(grep -n 'rm -rf "\$SHARED_TARGET"' "$REACTOR" | head -1 | cut -d: -f1)
if [[ -n "$guard_line" && -n "$rm_line" ]] && (( guard_line < rm_line )); then
  pass "not-quiescent guard precedes the rm (never deletes while builds hold the dir)"
else
  fail "quiescence guard must precede the delete (guard=$guard_line rm=$rm_line)"
fi

echo ""
if (( fails == 0 )); then echo "PASS test-disk-reactor-shared-target-quiesce"; exit 0
else echo "FAIL ($fails) test-disk-reactor-shared-target-quiesce"; exit 1; fi
