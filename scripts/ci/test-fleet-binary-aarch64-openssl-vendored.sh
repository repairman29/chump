#!/usr/bin/env bash
# scripts/ci/test-fleet-binary-aarch64-openssl-vendored.sh — INFRA-3836
#
# Regression guard for the 2026-08-24 fleet-wide deploy freeze: the
# aarch64-unknown-linux-gnu job in build-fleet-binaries.yml failed to
# cross-build openssl-sys v0.9.117 (no aarch64 system OpenSSL / pkg-config
# sysroot on the ubuntu-latest runner), which put the whole matrix run at
# conclusion=failure and starved node-refresh-chump.sh's green-main scanner
# (runs?...&status=success excludes a failed run even though the x86_64
# artifact inside it was fine) — every node stayed pinned at a ~833-commit-
# stale SHA that predates the Discord advisor subsystem.
#
# The fix (landed via EFFECTIVE-450, #4284) forces openssl's `vendored`
# feature for the aarch64-linux target so openssl-sys compiles OpenSSL from
# source with the gcc-aarch64 cross toolchain instead of hunting for a
# system package that doesn't exist on the runner. This test guards against
# someone removing that target-specific override (e.g. during a dependency
# bump) and silently reintroducing the freeze.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CARGO_TOML="$REPO_ROOT/Cargo.toml"
WORKFLOW="$REPO_ROOT/.github/workflows/build-fleet-binaries.yml"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$CARGO_TOML" ] || fail "missing $CARGO_TOML"
[ -f "$WORKFLOW" ] || fail "missing $WORKFLOW"

# The vendored-openssl override for the aarch64-linux cross target must exist,
# and it must actually enable the "vendored" feature (not just declare the
# dependency), or openssl-sys falls back to pkg-config and the freeze repeats.
awk '
  /target\.'"'"'cfg\(all\(target_arch = "aarch64", target_os = "linux"\)\)'"'"'\.dependencies/ { in_block=1; next }
  in_block && /^\[/ { in_block=0 }
  in_block && /openssl/ && /vendored/ { found=1 }
  END { exit found ? 0 : 1 }
' "$CARGO_TOML" \
  || fail "Cargo.toml is missing the aarch64-linux vendored-openssl override (see INFRA-3836)"
ok "Cargo.toml pins vendored openssl for the aarch64-linux cross target"

# The workflow must still install the aarch64 GNU cross toolchain the vendored
# build compiles against.
grep -q "gcc-aarch64-linux-gnu" "$WORKFLOW" \
  || fail "build-fleet-binaries.yml no longer installs gcc-aarch64-linux-gnu"
ok "build-fleet-binaries.yml installs the aarch64 cross toolchain"

exit 0
