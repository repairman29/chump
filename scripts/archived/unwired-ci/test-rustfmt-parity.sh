#!/usr/bin/env bash
# scripts/ci/test-rustfmt-parity.sh
#
# INFRA-2672: ensure local cargo fmt + CI cargo fmt produce byte-identical
# output by pinning the toolchain to an exact patch version (not floating
# "stable"). PR #3003's fast-checks failed today because local rustfmt
# produced 3 lines that differed from CI rustfmt — a subtle patch-version
# drift even when both used "stable".
#
# This guard asserts:
#   1. rust-toolchain.toml exists at repo root
#   2. rust-toolchain.toml `channel` is pinned to an explicit version
#      (e.g. "1.96.0"), NOT the floating "stable" or "nightly" or "beta"
#   3. The pinned version is a sensible semver-shape (X.Y.Z)
#
# If a future operator legitimately wants the floating channel, the override
# is to edit rust-toolchain.toml + remove the assertion here — the bypass is
# checked into source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOLCHAIN="$REPO_ROOT/rust-toolchain.toml"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Assert 1: rust-toolchain.toml exists ─────────────────────────────────────
if [[ -f "$TOOLCHAIN" ]]; then
    ok "rust-toolchain.toml present at repo root"
else
    fail "rust-toolchain.toml NOT FOUND at $TOOLCHAIN"
    echo "── Summary ──"
    echo "  PASS: $PASS  FAIL: $FAIL"
    exit 1
fi

# ── Assert 2: channel is pinned to an explicit version (not floating) ────────
channel_line="$(grep -E '^channel[[:space:]]*=' "$TOOLCHAIN" | head -1)"
if [[ -z "$channel_line" ]]; then
    fail "rust-toolchain.toml has no 'channel = ...' line"
    echo "── Summary ──"; echo "  PASS: $PASS  FAIL: $FAIL"
    exit 1
fi

channel_val="$(printf '%s' "$channel_line" | sed -E 's/^channel[[:space:]]*=[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/')"
echo "  rust-toolchain.toml channel = '$channel_val'"

case "$channel_val" in
    stable|beta|nightly)
        fail "channel '$channel_val' is floating — pin to an explicit X.Y.Z (e.g. \"1.96.0\") to prevent local↔CI rustfmt drift (INFRA-2672 reproducer: PR #3003 fast-checks fail 2026-06-03)"
        ;;
    [0-9]*.[0-9]*.[0-9]*)
        ok "channel pinned to explicit version '$channel_val'"
        ;;
    *)
        fail "channel '$channel_val' is neither a known floating channel nor an X.Y.Z patch — investigate"
        ;;
esac

# ── Assert 3: components include rustfmt + clippy ────────────────────────────
if grep -qE '^components[[:space:]]*=.*rustfmt' "$TOOLCHAIN" && \
   grep -qE '^components[[:space:]]*=.*clippy' "$TOOLCHAIN"; then
    ok "components include both rustfmt and clippy"
else
    fail "components missing rustfmt or clippy — preflight gates require both"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "── INFRA-2672 rustfmt parity summary ──"
echo "  PASS: $PASS  FAIL: $FAIL"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
