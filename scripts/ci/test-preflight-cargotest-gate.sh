#!/usr/bin/env bash
# test-preflight-cargotest-gate.sh — INFRA-1855 smoke test
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
ok()  { printf '\033[0;32mOK\033[0m   %s\n' "$*"; }
err() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; fail=1; }

PREFLIGHT="$REPO_ROOT/src/preflight.rs"
grep -q 'CHUMP_PREFLIGHT_SKIP_CARGOTEST' "$PREFLIGHT" \
    && ok "preflight.rs reads CHUMP_PREFLIGHT_SKIP_CARGOTEST" \
    || err "preflight.rs missing skip-env branch"
grep -q '"preflight_cargotest_bypassed"' "$PREFLIGHT" \
    && ok "preflight.rs emits preflight_cargotest_bypassed on skip" \
    || err "preflight.rs missing skip-ambient kind"
grep -q 'cargo-test-with-rerun\.sh' "$PREFLIGHT" \
    && ok "preflight.rs invokes cargo-test-with-rerun.sh" \
    || err "preflight.rs missing CI-script invocation"
[ -x "$REPO_ROOT/scripts/ci/cargo-test-with-rerun.sh" ] \
    && ok "cargo-test-with-rerun.sh present + executable" \
    || err "cargo-test-with-rerun.sh missing"
grep -q 'preflight_cargotest_bypassed' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt" \
    && ok "preflight_cargotest_bypassed allowlisted" \
    || err "preflight_cargotest_bypassed missing from event-registry-reserved.txt"

[ "$fail" = "0" ] && ok "INFRA-1855 cargo-test preflight gate smoke test PASSED"
exit "$fail"
