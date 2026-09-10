#!/usr/bin/env bash
# scripts/ci/test-resilient-1101-atc-naming.sh — RESILIENT-1101
#
# helsinki was decommissioned 2026-08-17 and the ATC installer's logic is
# node-neutral via --role brain|muscle, but the file was still named
# install-helsinki-atc.sh and organ-manifest.txt's header still described the
# desired state as "the PRIMARY node (helsinki)" — misleading naming/docs for
# a reproducible bring-up that no longer targets that box.
#
# Proves: (1) the node-neutral scripts/setup/install-atc.sh exists and is the
# real installer, (2) scripts/setup/install-helsinki-atc.sh is kept ONLY as a
# compat symlink to it (no behavior fork), (3) organ-manifest.txt's header no
# longer names helsinki as the primary node.
#
# Fails without the RESILIENT-1101 change because install-atc.sh did not
# exist (only install-helsinki-atc.sh, a real file) and the manifest header
# literally contained "(helsinki)".

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

INSTALLER="$REPO_ROOT/scripts/setup/install-atc.sh"
COMPAT="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

[ -f "$INSTALLER" ] || fail "missing node-neutral scripts/setup/install-atc.sh"
[ -x "$INSTALLER" ] || fail "scripts/setup/install-atc.sh is not executable"
bash -n "$INSTALLER" || fail "syntax error in install-atc.sh"
ok "scripts/setup/install-atc.sh exists and is executable"

[ -L "$COMPAT" ] || fail "scripts/setup/install-helsinki-atc.sh must be a compat symlink, not a real file"
TARGET="$(readlink "$COMPAT")"
[ "$TARGET" = "install-atc.sh" ] || fail "install-helsinki-atc.sh symlink must point at install-atc.sh, points at '$TARGET'"
ok "install-helsinki-atc.sh is a compat symlink to install-atc.sh"

grep -q 'PRIMARY node (helsinki)' "$MANIFEST" \
    && fail "organ-manifest.txt header still names helsinki as the PRIMARY node"
grep -q 'owned iron' "$MANIFEST" \
    || fail "organ-manifest.txt header should describe the primary node as owned iron, not a named box"
ok "organ-manifest.txt header no longer shapes the desired state around helsinki"
