#!/usr/bin/env bash
# test-disk-pressure-gate.sh — INFRA-975
#
# Exercises scripts/lib/disk-check.sh + verifies gap-claim.sh and worker.sh
# both source it. Uses a shim `df` on PATH to fake disk pressure.
#
# Scenarios:
#   1. df free > threshold: claim proceeds (chump_disk_check_or_abort returns 0)
#   2. df free < CHUMP_DISK_LOW_GB: claim aborts with kind=claim_aborted_disk_full
#   3. df free > critical: worker check returns 0 (proceed)
#   4. df free < CHUMP_DISK_CRITICAL_GB: worker check returns 1 + emits fleet_paused_disk_critical
#   5. CHUMP_DISK_CHECK_DISABLE=1: both helpers short-circuit
#   6. gap-claim.sh sources disk-check.sh
#   7. worker.sh sources disk-check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/disk-check.sh"
[[ -r "$LIB" ]] || { echo "FAIL: missing $LIB"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AMB="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$(dirname "$AMB")"

# Build a fake `df` we can switch between "lots of space" and "tight".
SHIM_DIR="$TMP/bin"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/df" <<'SHIM'
#!/usr/bin/env bash
# CHUMP_TEST_FAKE_KB controls the 4th column ("Available" in 1K blocks).
KB="${CHUMP_TEST_FAKE_KB:-100000000}"  # default 100 GB free
printf 'Filesystem 1K-blocks Used Available Capacity Mounted on\n'
printf '/dev/test  999999999 0 %s 0%% /test\n' "$KB"
SHIM
chmod +x "$SHIM_DIR/df"

# Source the lib with fake df on PATH.
test_one() {
  env \
    PATH="$SHIM_DIR:/usr/bin:/bin" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_TEST_FAKE_KB="$1" \
    "${@:2}" \
    bash -c '
      source "'"$LIB"'"
      shift
      "$@"
    ' _ "${@:3}"
}

# Scenario 1: lots of space → claim should proceed.
: > "$AMB"
# 100 GB free, threshold default 5 GB
test_one 104857600 bash -c 'source "'"$LIB"'"; chump_disk_check_or_abort && echo PROCEED' >/dev/null
ok "abundant disk: chump_disk_check_or_abort returns 0 (no abort)"
[[ ! -s "$AMB" ]] || fail "abundant disk: ambient should be empty"

# Scenario 2: tight disk → claim aborts with ambient event.
: > "$AMB"
# 2 GB free, threshold default 5 GB → should abort
if env PATH="$SHIM_DIR:/usr/bin:/bin" CHUMP_AMBIENT_LOG="$AMB" CHUMP_TEST_FAKE_KB=2097152 \
   bash -c 'source "'"$LIB"'"; chump_disk_check_or_abort' 2>/dev/null; then
  fail "tight disk: chump_disk_check_or_abort should have exited non-zero"
fi
grep -q '"kind":"claim_aborted_disk_full"' "$AMB" \
  || fail "tight disk: claim_aborted_disk_full event missing"
grep -q '"free_gb":2' "$AMB" \
  || fail "tight disk: free_gb field missing/wrong: $(cat $AMB)"
ok "tight disk (2 GB): aborts + emits claim_aborted_disk_full"

# Scenario 3: above critical → worker proceeds.
: > "$AMB"
env PATH="$SHIM_DIR:/usr/bin:/bin" CHUMP_AMBIENT_LOG="$AMB" CHUMP_TEST_FAKE_KB=10485760 \
  bash -c 'source "'"$LIB"'"; chump_disk_check_pause_worker' \
  || fail "10 GB free: worker should not pause"
ok "worker check: 10 GB free → proceed"

# Scenario 4: below critical → worker pauses + emits event.
: > "$AMB"
if env PATH="$SHIM_DIR:/usr/bin:/bin" CHUMP_AMBIENT_LOG="$AMB" CHUMP_TEST_FAKE_KB=524288 \
   bash -c 'source "'"$LIB"'"; chump_disk_check_pause_worker' 2>/dev/null; then
  fail "0.5 GB free: worker should pause (return 1)"
fi
grep -q '"kind":"fleet_paused_disk_critical"' "$AMB" \
  || fail "critical disk: fleet_paused_disk_critical event missing"
ok "worker check: <1 GB free → pause + emits fleet_paused_disk_critical"

# Scenario 5: DISABLE env short-circuits both helpers.
: > "$AMB"
env PATH="$SHIM_DIR:/usr/bin:/bin" CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_TEST_FAKE_KB=524288 CHUMP_DISK_CHECK_DISABLE=1 \
  bash -c 'source "'"$LIB"'"; chump_disk_check_or_abort && chump_disk_check_pause_worker' \
  || fail "DISABLE=1: both helpers should be no-ops (return 0)"
[[ ! -s "$AMB" ]] || fail "DISABLE=1: no ambient events should be emitted"
ok "CHUMP_DISK_CHECK_DISABLE=1: both helpers short-circuit (no abort, no emit)"

# Scenarios 6+7: gap-claim.sh + worker.sh source the lib.
grep -q 'disk-check.sh' "$REPO_ROOT/scripts/coord/gap-claim.sh" \
  || fail "gap-claim.sh does not source disk-check.sh"
ok "gap-claim.sh sources disk-check.sh"

grep -q 'disk-check.sh' "$REPO_ROOT/scripts/dispatch/worker.sh" \
  || fail "worker.sh does not source disk-check.sh"
ok "worker.sh sources disk-check.sh"

echo
echo "=== test-disk-pressure-gate.sh PASSED ==="
