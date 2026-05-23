#!/usr/bin/env bash
# test-preflight-acpsmoke-gate.sh — INFRA-1859 smoke test
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
ok()  { printf '\033[0;32mOK\033[0m   %s\n' "$*"; }
err() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; fail=1; }

PREFLIGHT="$REPO_ROOT/src/preflight.rs"
grep -q 'CHUMP_PREFLIGHT_SKIP_ACPSMOKE' "$PREFLIGHT" \
    && ok "preflight.rs reads CHUMP_PREFLIGHT_SKIP_ACPSMOKE" \
    || err "preflight.rs missing skip-env branch"
grep -q '"preflight_acpsmoke_bypassed"' "$PREFLIGHT" \
    && ok "preflight.rs emits preflight_acpsmoke_bypassed on skip" \
    || err "preflight.rs missing skip-ambient kind"
grep -q 'test-acp-smoke\.sh' "$PREFLIGHT" \
    && ok "preflight.rs invokes test-acp-smoke.sh" \
    || err "preflight.rs missing CI-script invocation"

[ -x "$REPO_ROOT/scripts/ci/test-acp-smoke.sh" ] \
    && ok "test-acp-smoke.sh present + executable" \
    || err "test-acp-smoke.sh missing or not executable"

grep -q 'preflight_acpsmoke_bypassed' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt" \
    && ok "preflight_acpsmoke_bypassed allowlisted" \
    || err "preflight_acpsmoke_bypassed missing from event-registry-reserved.txt"

[ "$fail" = "0" ] && ok "INFRA-1859 acp-smoke preflight gate smoke test PASSED"
exit "$fail"
