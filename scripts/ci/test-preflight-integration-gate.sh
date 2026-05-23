#!/usr/bin/env bash
# test-preflight-integration-gate.sh — INFRA-1857 smoke test

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
ok()  { printf '\033[0;32mOK\033[0m   %s\n' "$*"; }
err() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; fail=1; }

# preflight.rs wiring
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
grep -q 'CHUMP_PREFLIGHT_SKIP_INTEGRATION' "$PREFLIGHT" \
    && ok "preflight.rs reads CHUMP_PREFLIGHT_SKIP_INTEGRATION" \
    || err "preflight.rs missing skip-env branch"
grep -q '"preflight_integration_bypassed"' "$PREFLIGHT" \
    && ok "preflight.rs emits preflight_integration_bypassed on skip" \
    || err "preflight.rs missing skip-ambient kind"
grep -q 'test-system-integration\.sh' "$PREFLIGHT" \
    && ok "preflight.rs invokes test-system-integration.sh" \
    || err "preflight.rs missing CI-script invocation"

# Underlying CI script must exist
[ -x "$REPO_ROOT/scripts/ci/test-system-integration.sh" ] \
    && ok "scripts/ci/test-system-integration.sh present + executable" \
    || err "test-system-integration.sh missing or not executable"

# event-registry allowlist
grep -q 'preflight_integration_bypassed' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt" \
    && ok "preflight_integration_bypassed allowlisted" \
    || err "preflight_integration_bypassed missing from event-registry-reserved.txt"

[ "$fail" = "0" ] && ok "INFRA-1857 integration-test preflight gate smoke test PASSED"
exit "$fail"
