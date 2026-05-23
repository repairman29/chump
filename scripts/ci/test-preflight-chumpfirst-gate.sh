#!/usr/bin/env bash
# test-preflight-chumpfirst-gate.sh — INFRA-1858 smoke test
#
# Asserts the wiring of the chump-first-contract preflight gate (CREDIBLE-046 mirror).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
ok()  { printf '\033[0;32mOK\033[0m   %s\n' "$*"; }
err() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; fail=1; }

WRAPPER="$REPO_ROOT/scripts/ci/check-chump-first-contract.sh"
[ -x "$WRAPPER" ] && ok "wrapper present + executable" || err "missing or not executable: $WRAPPER"

# preflight.rs wiring
PREFLIGHT="$REPO_ROOT/src/preflight.rs"
grep -q 'CHUMP_PREFLIGHT_SKIP_CHUMPFIRST' "$PREFLIGHT" \
    && ok "preflight.rs reads CHUMP_PREFLIGHT_SKIP_CHUMPFIRST" \
    || err "preflight.rs missing skip-env branch"
grep -q '"preflight_chumpfirst_bypassed"' "$PREFLIGHT" \
    && ok "preflight.rs emits preflight_chumpfirst_bypassed on skip" \
    || err "preflight.rs missing skip-ambient kind"
grep -q 'check-chump-first-contract\.sh' "$PREFLIGHT" \
    && ok "preflight.rs invokes check-chump-first-contract.sh" \
    || err "preflight.rs missing wrapper invocation"

# wrapper scrubs Anthropic creds
grep -q 'ANTHROPIC_API_KEY=""' "$WRAPPER" \
    && ok "wrapper scrubs ANTHROPIC_API_KEY" || err "wrapper missing ANTHROPIC_API_KEY scrub"
grep -q 'CLAUDE_CODE_OAUTH_TOKEN=""' "$WRAPPER" \
    && ok "wrapper scrubs CLAUDE_CODE_OAUTH_TOKEN" || err "wrapper missing OAUTH scrub"

# wrapper delegates to existing CI script
grep -q 'test-no-anthropic-smoke\.sh' "$WRAPPER" \
    && ok "wrapper invokes test-no-anthropic-smoke.sh" \
    || err "wrapper missing test-no-anthropic-smoke.sh invocation"

# event-registry allowlist
grep -q 'preflight_chumpfirst_bypassed' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt" \
    && ok "preflight_chumpfirst_bypassed allowlisted" \
    || err "preflight_chumpfirst_bypassed missing from event-registry-reserved.txt"

[ "$fail" = "0" ] && ok "INFRA-1858 chump-first-contract preflight gate smoke test PASSED"
exit "$fail"
