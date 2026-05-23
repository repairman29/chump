#!/usr/bin/env bash
# test-preflight-prhygiene-gate.sh — INFRA-1854 smoke test
#
# Asserts:
#   1. scripts/ci/check-pr-hygiene.sh exists + executable
#   2. CHUMP_PREFLIGHT_SKIP_PRHYGIENE=1 env is read (substring present in preflight.rs)
#   3. preflight_prhygiene_bypassed event-kind reachable via the skip path

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
ok()  { printf '\033[0;32mOK\033[0m   %s\n' "$*"; }
err() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; fail=1; }

# 1. wrapper script present + executable
WRAPPER="$REPO_ROOT/scripts/ci/check-pr-hygiene.sh"
[ -x "$WRAPPER" ] && ok "check-pr-hygiene.sh present + executable" || err "missing or not executable: $WRAPPER"

# 2. preflight.rs has the gate wired with skip-env + ambient emit
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
grep -q 'CHUMP_PREFLIGHT_SKIP_PRHYGIENE' "$PREFLIGHT" \
    && ok "preflight.rs reads CHUMP_PREFLIGHT_SKIP_PRHYGIENE" \
    || err "preflight.rs missing CHUMP_PREFLIGHT_SKIP_PRHYGIENE branch"

grep -q '"preflight_prhygiene_bypassed"' "$PREFLIGHT" \
    && ok "preflight.rs emits preflight_prhygiene_bypassed on skip" \
    || err "preflight.rs missing preflight_prhygiene_bypassed kind"

grep -q 'check-pr-hygiene\.sh' "$PREFLIGHT" \
    && ok "preflight.rs invokes check-pr-hygiene.sh on run" \
    || err "preflight.rs missing check-pr-hygiene.sh step push"

# 3. wrapper script wraps the 2 sub-checks (CREDIBLE-027 + INFRA-1568)
grep -q 'check-mass-deletion' "$WRAPPER" \
    && ok "wrapper invokes check-mass-deletion (CREDIBLE-027)" \
    || err "wrapper missing check-mass-deletion call"
grep -q 'broad-canary\|test-runner-lane-broad-canary' "$WRAPPER" \
    && ok "wrapper invokes broad-canary (INFRA-1568)" \
    || err "wrapper missing broad-canary call"

# 4. event-registry allowlist has the new kind
grep -q 'preflight_prhygiene_bypassed' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt" \
    && ok "preflight_prhygiene_bypassed allowlisted" \
    || err "preflight_prhygiene_bypassed missing from event-registry-reserved.txt"

[ "$fail" = "0" ] && ok "INFRA-1854 pr-hygiene preflight gate smoke test PASSED"
exit "$fail"
