#!/usr/bin/env bash
# scripts/ci/test-organ-oneshot-timeout.sh — operator-ordered organ oneshot timeout (2026-10-10)
#
# systemd gives Type=oneshot units no start timeout by default, so a single hung
# script wedged chump-organ-watchdog and the outcome-verify heal consumer for
# 20+ min each (and a timer cannot re-fire a unit still "activating").
# organ_unit_host_rewrite (the ONE generator for organ units, both scopes) must
# therefore inject a bounded TimeoutStartSec into every Type=oneshot unit that
# does not pin its own, and leave explicit values and non-oneshot units alone.
#
# Depth: happy-path + edge (explicit value preserved, non-oneshot untouched,
# env override, both scopes, idempotent). NOT covered: a live systemd actually
# killing a hung run (verified by hand on cuphead 2026-10-10).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
[ -f "$LIB" ] || { echo "FAIL: lib not found: $LIB"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-organ-oneshot-timeout.sh ==="
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-oneshot-timeout.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mk() {  # name, body
  printf '%s\n' "$2" > "$TMP/$1"
}
mk plain.service $'[Unit]\nDescription=x\n[Service]\nType=oneshot\nExecStart=/bin/true'
mk explicit.service $'[Unit]\nDescription=x\n[Service]\nType=oneshot\nTimeoutStartSec=1800\nExecStart=/bin/true'
mk daemon.service $'[Unit]\nDescription=x\n[Service]\nType=simple\nExecStart=/bin/sleep infinity'
mk notype.service $'[Unit]\nDescription=x\n[Service]\nExecStart=/bin/sleep infinity'

for scope in system user; do
  rm -f "$TMP"/out-*.service
  for u in plain explicit daemon notype; do
    organ_unit_host_rewrite "$TMP/$u.service" "$TMP/out-$u.service" ubuntu /home/ubuntu 0 "$TMP" "$scope" || fail "[$scope] rewrite failed for $u"
  done
  grep -qx 'TimeoutStartSec=600' "$TMP/out-plain.service" \
    && pass "[$scope] oneshot without a timeout gets TimeoutStartSec=600" \
    || fail "[$scope] oneshot without a timeout did not get TimeoutStartSec=600"
  [ "$(grep -c '^TimeoutStartSec=' "$TMP/out-plain.service")" = 1 ] \
    && pass "[$scope] exactly one TimeoutStartSec line" || fail "[$scope] duplicate TimeoutStartSec lines"
  grep -qx 'TimeoutStartSec=1800' "$TMP/out-explicit.service" && [ "$(grep -c '^TimeoutStartSec=' "$TMP/out-explicit.service")" = 1 ] \
    && pass "[$scope] explicit TimeoutStartSec=1800 preserved, not duplicated" || fail "[$scope] explicit timeout clobbered"
  ! grep -q '^TimeoutStartSec=' "$TMP/out-daemon.service" \
    && pass "[$scope] Type=simple daemon untouched" || fail "[$scope] daemon got a start timeout"
  ! grep -q '^TimeoutStartSec=' "$TMP/out-notype.service" \
    && pass "[$scope] unit with no Type= untouched" || fail "[$scope] typeless unit got a start timeout"
  # the timeout line must sit inside [Service]
  awk '/^\[Service\]/{s=1;next} /^\[/{s=0} s&&/^TimeoutStartSec=/{f=1} END{exit f?0:1}' "$TMP/out-plain.service" \
    && pass "[$scope] TimeoutStartSec lands inside [Service]" || fail "[$scope] TimeoutStartSec not inside [Service]"
done

CHUMP_ORGAN_ONESHOT_TIMEOUT_S=45 organ_unit_host_rewrite "$TMP/plain.service" "$TMP/out-env.service" ubuntu /home/ubuntu 0 "$TMP" user
grep -qx 'TimeoutStartSec=45' "$TMP/out-env.service" \
  && pass "CHUMP_ORGAN_ONESHOT_TIMEOUT_S overrides the default" || fail "env override ignored"

# real tracked organ units: the two that wedged must come out bounded
for u in chump-organ-watchdog chump-outcome-verify-heal-consumer; do
  organ_unit_host_rewrite "$REPO_ROOT/scripts/dispatch/$u.service" "$TMP/real-$u.service" ubuntu /home/ubuntu 0 "$REPO_ROOT" user
  grep -qx 'TimeoutStartSec=600' "$TMP/real-$u.service" \
    && pass "tracked $u.service is bounded after rewrite" || fail "tracked $u.service not bounded after rewrite"
done

if [ "$fails" -gt 0 ]; then echo "=== $fails FAILED ==="; exit 1; fi
echo "=== all organ-oneshot-timeout tests passed ==="
