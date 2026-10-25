#!/usr/bin/env bash
# RESILIENT-1694: fleet-doctor organ-home check (missing home / off-home RED, on-home GREEN).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "  ✗ $*" >&2; exit 1; }
grep -E '^enabled' "$ROOT/scripts/ops/organ-manifest.txt" | grep -vq 'home=' && fail "real manifest has enabled line without home="
printf '#!/bin/sh\nexit 0\n' > "$T/systemctl"; chmod +x "$T/systemctl"
run() { CHUMP_ORGAN_MANIFEST="$1" CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$T/systemctl" CHUMP_ORGAN_MANIFEST_NODE=nodeA \
  bash -c "source <(sed -n '/^check_organ_home() {/,/^}/p' '$ROOT/scripts/coord/fleet-doctor-strict.sh'); register_check() { echo \"\$2\"; }; REPO_ROOT='$ROOT'; check_organ_home"; }
printf 'enabled x.service role=brain home=nodeA\n' > "$T/ok"
printf 'enabled x.service role=brain\n' > "$T/nohome"
printf 'enabled x.service role=brain home=nodeB\n' > "$T/off"
[[ "$(run "$T/ok")" == pass ]] || fail "on-home should pass"
[[ "$(run "$T/nohome")" == fail ]] || fail "missing home should fail"
[[ "$(run "$T/off")" == fail ]] || fail "off-home should fail"
echo "  ✓ organ-home check OK"
