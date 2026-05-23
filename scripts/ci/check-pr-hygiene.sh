#!/usr/bin/env bash
# check-pr-hygiene.sh — INFRA-1854 local mirror of the ci.yml pr-hygiene job
#
# Wraps the 2 currently-uncovered pr-hygiene sub-checks (INFRA-1792 already
# mirrors the third — check-pr-scope.sh — via preflight pr-scope-sanity gate):
#   - check-mass-deletion.sh (CREDIBLE-027 mass-deletion / scratch-commit guard)
#   - test-runner-lane-broad-canary.sh (INFRA-1568 broad canary coverage smoke)
#
# Used by src/preflight.rs as the pr-hygiene local gate. Designed to be safe
# to run without gh CLI auth (each sub-script handles its own gh-missing case).
#
# Bypass: CHUMP_PREFLIGHT_SKIP_PRHYGIENE=1 (handled in preflight.rs caller)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail=0
ok()   { printf '\033[0;32m[pr-hygiene] OK\033[0m   %s\n' "$*"; }
warn() { printf '\033[0;33m[pr-hygiene] WARN\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[pr-hygiene] FAIL\033[0m %s\n' "$*" >&2; fail=1; }

# ── 1. mass-deletion / scratch-commit guard (CREDIBLE-027) ───────────────────
if [ -x "scripts/ci/check-mass-deletion.sh" ]; then
    if bash scripts/ci/check-mass-deletion.sh; then
        ok "check-mass-deletion (CREDIBLE-027)"
    else
        err "check-mass-deletion (CREDIBLE-027) — see output above"
    fi
else
    warn "scripts/ci/check-mass-deletion.sh missing — skipping CREDIBLE-027"
fi

# ── 2. broad canary coverage smoke (INFRA-1568) ─────────────────────────────
if [ -x "scripts/setup/test-runner-lane-broad-canary.sh" ]; then
    if bash scripts/setup/test-runner-lane-broad-canary.sh; then
        ok "broad-canary coverage (INFRA-1568)"
    else
        err "broad-canary coverage (INFRA-1568) — see output above"
    fi
else
    warn "scripts/setup/test-runner-lane-broad-canary.sh missing — skipping INFRA-1568"
fi

# check-pr-scope.sh is intentionally NOT run here — INFRA-1792 already
# mirrors it via preflight's pr-scope-sanity gate (no double-run).

if [ "$fail" = "0" ]; then
    ok "pr-hygiene local mirror — all sub-checks passed"
fi
exit "$fail"
