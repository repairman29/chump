#!/usr/bin/env bash
# scripts/ci/test-buildbuddy-fallback.sh — INFRA-2249
#
# Asserts the sccache config surface exposes BOTH a BuildBuddy URL AND an
# R2 fallback URL, so a missing/rotated BuildBuddy key degrades to the
# existing R2 backend (INFRA-2093) instead of failing the build outright.
# Static config check — does not require network access or real secrets.
#
# Bypass:
#   CHUMP_BUILDBUDDY_FALLBACK_DISABLE=1 — exits 0 unconditionally
#
# Exit codes:
#   0 — both backends wired
#   1 — one or both missing

set -uo pipefail

if [ "${CHUMP_BUILDBUDDY_FALLBACK_DISABLE:-0}" = "1" ]; then
    echo "SKIP: CHUMP_BUILDBUDDY_FALLBACK_DISABLE=1"
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-2249 BuildBuddy/R2 fallback wiring audit ==="
echo

# ── 1. install-sccache.sh generates a config wiring the passthrough shim ─────
# .cargo/config.toml itself is .gitignored (INFRA-202 — per-machine, a CI
# runner without sccache installed would break if it were committed), so
# we check the generator script rather than a file that won't exist in a
# fresh CI checkout.
echo "[1. install-sccache.sh rustc-wrapper + BuildBuddy wiring]"
if [ -f scripts/setup/install-sccache.sh ] && grep -q 'rustc-wrapper.*sccache-or-rustc\.sh' scripts/setup/install-sccache.sh; then
    ok "scripts/setup/install-sccache.sh wires build.rustc-wrapper to the sccache-or-rustc shim"
else
    fail "scripts/setup/install-sccache.sh missing or does not wire scripts/ci/sccache-or-rustc.sh"
fi

if [ -f scripts/setup/install-sccache.sh ] && grep -q 'SCCACHE_BUILDBUDDY_URL' scripts/setup/install-sccache.sh; then
    ok "scripts/setup/install-sccache.sh offers opt-in BuildBuddy remote cache"
else
    fail "scripts/setup/install-sccache.sh does not wire SCCACHE_BUILDBUDDY_URL"
fi

if [ -x scripts/ci/sccache-or-rustc.sh ]; then
    ok "scripts/ci/sccache-or-rustc.sh exists and is executable"
else
    fail "scripts/ci/sccache-or-rustc.sh missing or not executable"
fi

# ── 2. BuildBuddy URL wired in CI workflows ───────────────────────────────────
echo "[2. SCCACHE_BUILDBUDDY_URL present in CI workflows]"
buildbuddy_wired=0
for wf in .github/workflows/ci.yml .github/workflows/audit.yml; do
    if [ -f "$wf" ] && grep -q 'SCCACHE_BUILDBUDDY_URL' "$wf"; then
        buildbuddy_wired=1
    fi
done
if [ "$buildbuddy_wired" = 1 ]; then
    ok "SCCACHE_BUILDBUDDY_URL wired in at least one CI workflow"
else
    fail "SCCACHE_BUILDBUDDY_URL not found in ci.yml or audit.yml"
fi

# ── 3. R2 fallback URL still wired (never removed) ────────────────────────────
echo "[3. SCCACHE_ENDPOINT (R2 fallback) present in CI workflows]"
r2_wired=0
for wf in .github/workflows/ci.yml .github/workflows/audit.yml; do
    if [ -f "$wf" ] && grep -q 'SCCACHE_ENDPOINT' "$wf"; then
        r2_wired=1
    fi
done
if [ "$r2_wired" = 1 ]; then
    ok "SCCACHE_ENDPOINT (R2) wired in at least one CI workflow"
else
    fail "SCCACHE_ENDPOINT not found — R2 fallback appears to have been removed"
fi

# ── 4. Backend-selection logic prefers BuildBuddy, falls back to R2 ──────────
echo "[4. backend-selection precedence]"
precedence_ok=0
for wf in .github/workflows/ci.yml .github/workflows/audit.yml; do
    if [ -f "$wf" ] && grep -q 'backend=buildbuddy' "$wf" && grep -q 'backend=r2' "$wf"; then
        precedence_ok=1
    fi
done
if [ "$precedence_ok" = 1 ]; then
    ok "at least one workflow emits both backend=buildbuddy and backend=r2 outputs"
else
    fail "no workflow found emitting both backend=buildbuddy and backend=r2 — fallback precedence not wired"
fi

echo
echo "=== Summary: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ]
