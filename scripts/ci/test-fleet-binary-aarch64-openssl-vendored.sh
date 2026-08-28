#!/usr/bin/env bash
# scripts/ci/test-fleet-binary-aarch64-openssl-vendored.sh — INFRA-3836
#
# Regression guard for the fix that unstuck build-fleet-binaries.yml: the
# aarch64-unknown-linux-gnu matrix job cross-compiles from an x86_64 GH
# runner with no system OpenSSL / pkg-config sysroot for the target arch, so
# `openssl-sys` fails with "Could not find openssl via pkg-config" unless
# openssl's `vendored` feature is forced for that target (compiles OpenSSL
# from source with the gcc-aarch64 cross toolchain the workflow installs).
#
# Because build-fleet-binaries.yml has `fail-fast: false`, a red aarch64 job
# marks the WHOLE run conclusion=failure even though x86_64 succeeded — and
# node-refresh-chump.sh's green-main scanner only accepts whole-run
# status=success, so it fell back to a green-main pin ~833 commits stale
# (predating the Discord advisor subsystem). If this Cargo.toml override is
# ever silently dropped (e.g. during a dependency-bump PR), the fleet-wide
# deploy freeze regresses with no other gate catching it until the next
# build-fleet-binaries.yml run goes red on main.
#
# Pure grep, no network, no cargo, <1s.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CARGO_TOML="$REPO_ROOT/Cargo.toml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$CARGO_TOML" ] || fail "missing $CARGO_TOML"

# The aarch64-linux cfg block must exist...
grep -qE '^\[target\.'"'"'cfg\(all\(target_arch = "aarch64", target_os = "linux"\)\)'"'"'\.dependencies\]' \
    "$CARGO_TOML" \
    || fail "no [target.'cfg(all(target_arch = \"aarch64\", target_os = \"linux\"))'.dependencies] section in Cargo.toml"
ok "aarch64-linux target-specific dependency section present"

# ...and it must force openssl's vendored feature (the actual fix), not just
# exist as an empty/unrelated block.
HEADER_LINE="$(grep -nE '^\[target\.'"'"'cfg\(all\(target_arch = "aarch64", target_os = "linux"\)\)'"'"'\.dependencies\]' "$CARGO_TOML" | head -1 | cut -d: -f1)"
AARCH64_BLOCK="$(tail -n "+$((HEADER_LINE + 1))" "$CARGO_TOML" | awk '/^\[/{exit} {print}')"

echo "$AARCH64_BLOCK" | grep -qE '^openssl[[:space:]]*=.*vendored' \
    || fail "aarch64-linux dependency block does not force openssl vendored feature: $AARCH64_BLOCK"
ok "aarch64-linux block forces openssl { features = [\"vendored\"] } — cross-build openssl-sys wall stays fixed"

exit 0
