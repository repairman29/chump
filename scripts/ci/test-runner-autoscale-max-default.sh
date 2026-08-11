#!/usr/bin/env bash
# INFRA-3561 (INFRA-1655 slice): regression guard for the INFRA-3549 fix.
#
# INFRA-3547 found the M4 runner autoscaler's ceiling (CHUMP_RUNNER_M4_MAX)
# defaulted to 2 while the fleet has 4 physical M4 runners, capping the
# queue-contention mitigation the autoscaler exists to provide at half of
# real capacity. INFRA-3549 raised the default to 4 in both places it's
# baked in. This test guards against either place silently reverting to 2
# (or drifting out of sync with each other).
set -euo pipefail

AUTOSCALE_SH="scripts/coord/chump-runner-autoscale.sh"
INSTALL_SH="scripts/setup/install-runner-autoscale.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$AUTOSCALE_SH" ] || fail "$AUTOSCALE_SH not found"
[ -f "$INSTALL_SH" ] || fail "$INSTALL_SH not found"

autoscale_default=$(grep -E '^MAX_RUNNERS=' "$AUTOSCALE_SH" | head -1)
[ -n "$autoscale_default" ] || fail "$AUTOSCALE_SH missing MAX_RUNNERS= assignment"

printf '%s\n' "$autoscale_default" | grep -q 'CHUMP_RUNNER_M4_MAX:-4' \
  || fail "$AUTOSCALE_SH MAX_RUNNERS default is not CHUMP_RUNNER_M4_MAX:-4 (INFRA-3549 regression) — got: $autoscale_default"

install_default=$(grep -E '<string>\$\{CHUMP_RUNNER_M4_MAX:-[0-9]+\}</string>' "$INSTALL_SH" | head -1)
[ -n "$install_default" ] || fail "$INSTALL_SH missing CHUMP_RUNNER_M4_MAX plist default"

printf '%s\n' "$install_default" | grep -q 'CHUMP_RUNNER_M4_MAX:-4' \
  || fail "$INSTALL_SH CHUMP_RUNNER_M4_MAX plist default is not 4 (INFRA-3549 regression) — got: $install_default"

echo "OK: CHUMP_RUNNER_M4_MAX default is 4 in both $AUTOSCALE_SH and $INSTALL_SH (INFRA-3549 fix intact)"
