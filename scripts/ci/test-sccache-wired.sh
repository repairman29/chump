#!/usr/bin/env bash
# scripts/ci/test-sccache-wired.sh — INFRA-2093
#
# Verifies sccache + Cloudflare R2 are wired correctly in CI. Three modes:
#
#   Mode 1 (default, advisory): runs in any environment. If R2 secrets are
#     not set, exits 0 with WARN — operator hasn't completed setup yet, that's
#     expected during rollout.
#
#   Mode 2 (--require-rustc-wrapper): asserts RUSTC_WRAPPER=sccache when
#     R2 secrets are present. Used by CI to catch regressions where the env
#     block becomes inconsistent.
#
#   Mode 3 (--require-reachable): asserts the configured R2 endpoint is
#     reachable (curl to SCCACHE_ENDPOINT returns a response, even if it's
#     401/403 — we just want to confirm DNS + TCP work). Network-sensitive,
#     usually only run in dedicated diagnostic step.
#
# Bypass:
#   CHUMP_SCCACHE_WIRED_DISABLE=1 — exits 0 unconditionally
#
# Exit codes:
#   0 — wired correctly (or R2 secrets not yet set in advisory mode)
#   1 — required assertion failed in --require-* mode

set -uo pipefail

ADVISORY=1
REQUIRE_WRAPPER=0
REQUIRE_REACHABLE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --require-rustc-wrapper) ADVISORY=0; REQUIRE_WRAPPER=1; shift ;;
        --require-reachable)     ADVISORY=0; REQUIRE_REACHABLE=1; shift ;;
        -h|--help)               sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ "${CHUMP_SCCACHE_WIRED_DISABLE:-0}" = "1" ]; then
    echo "SKIP: CHUMP_SCCACHE_WIRED_DISABLE=1"
    exit 0
fi

PASS=0
FAIL=0
WARN=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
warn() { printf '\033[0;33mWARN\033[0m %s\n' "$*" >&2; WARN=$((WARN+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-2093 sccache + R2 wiring audit ==="
echo

# ── 1. R2 secrets configured? ─────────────────────────────────────────────────
echo "[1. R2 secrets in env]"

# In CI these come from the workflow env block; we just check they are set
# and non-empty. Don't print values — they are secrets.
have_aws_key=0
have_aws_secret=0
have_endpoint=0
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && have_aws_key=1
[ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && have_aws_secret=1
[ -n "${SCCACHE_ENDPOINT:-}" ] && have_endpoint=1

if [ "$have_aws_key" = 1 ] && [ "$have_aws_secret" = 1 ] && [ "$have_endpoint" = 1 ]; then
    ok "AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY + SCCACHE_ENDPOINT all present"
else
    msg="missing:"
    [ "$have_aws_key" = 0 ] && msg+=" AWS_ACCESS_KEY_ID"
    [ "$have_aws_secret" = 0 ] && msg+=" AWS_SECRET_ACCESS_KEY"
    [ "$have_endpoint" = 0 ] && msg+=" SCCACHE_ENDPOINT"
    if [ "$ADVISORY" = 1 ]; then
        warn "R2 secrets not (fully) set — $msg. Operator hasn't completed R2 setup yet (see docs/process/SCCACHE_R2_CACHE.md). Skipping further checks."
        echo "=== Summary: $PASS pass, $FAIL fail, $WARN warn ==="
        exit 0
    else
        fail "R2 secrets missing — $msg"
    fi
fi

# ── 2. SCCACHE_BUCKET + SCCACHE_REGION set ────────────────────────────────────
echo "[2. SCCACHE_BUCKET + SCCACHE_REGION]"
if [ -n "${SCCACHE_BUCKET:-}" ]; then
    ok "SCCACHE_BUCKET = ${SCCACHE_BUCKET}"
else
    fail "SCCACHE_BUCKET is empty"
fi
if [ -n "${SCCACHE_REGION:-}" ]; then
    ok "SCCACHE_REGION = ${SCCACHE_REGION}"
else
    fail "SCCACHE_REGION is empty (R2 expects 'auto')"
fi

# ── 3. RUSTC_WRAPPER assertion (mode 2) ───────────────────────────────────────
echo "[3. RUSTC_WRAPPER=sccache]"
if [ "${RUSTC_WRAPPER:-}" = "sccache" ]; then
    ok "RUSTC_WRAPPER=sccache"
elif [ "$REQUIRE_WRAPPER" = 1 ]; then
    fail "RUSTC_WRAPPER='${RUSTC_WRAPPER:-}' — expected 'sccache' (R2 secrets are set; --require-rustc-wrapper)"
else
    warn "RUSTC_WRAPPER='${RUSTC_WRAPPER:-}' — sccache not active in this env"
fi

# ── 4. sccache binary available (informational) ───────────────────────────────
echo "[4. sccache binary]"
if command -v sccache >/dev/null 2>&1; then
    ok "sccache on PATH: $(command -v sccache)"
else
    if [ "$RUSTC_WRAPPER" = "sccache" ]; then
        fail "RUSTC_WRAPPER=sccache but sccache binary not on PATH (install via mozilla-actions/sccache-action@v0.0.5 in workflow)"
    else
        warn "sccache not on PATH (informational; RUSTC_WRAPPER is not 'sccache')"
    fi
fi

# ── 5. R2 endpoint reachable (mode 3) ─────────────────────────────────────────
if [ "$REQUIRE_REACHABLE" = 1 ]; then
    echo "[5. SCCACHE_ENDPOINT reachable]"
    if [ -z "${SCCACHE_ENDPOINT:-}" ]; then
        fail "SCCACHE_ENDPOINT empty; cannot test reachability"
    else
        # We don't need 200 — any HTTP response (incl 401/403) proves DNS + TCP.
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${SCCACHE_ENDPOINT}" 2>/dev/null || echo '000')"
        case "$http_code" in
            000) fail "no HTTP response from ${SCCACHE_ENDPOINT} (DNS or TCP fail)" ;;
            5*)  fail "5xx from ${SCCACHE_ENDPOINT} (HTTP ${http_code}) — R2 service issue" ;;
            *)   ok  "endpoint responds (HTTP ${http_code}) — DNS + TCP healthy" ;;
        esac
    fi
fi

echo
echo "=== Summary: $PASS pass, $FAIL fail, $WARN warn ==="

if [ "$FAIL" -gt 0 ]; then
    echo "FAIL: see warnings above; fix env block or operator-side R2 setup." >&2
    exit 1
fi
exit 0
