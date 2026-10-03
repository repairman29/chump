#!/usr/bin/env bash
# test-preflight-parity.sh — INFRA-5432 (INFRA-1861 slice)
#
# Local-vs-CI parity smoke: confirms `chump preflight` is runnable (AC1),
# then delegates the actual gate-by-gate diff against .github/workflows/*.yml
# to the existing, more thorough scripts/ci/test-preflight-ci-parity.sh
# (INFRA-1867 / INFRA-2084 / META-268) rather than re-implementing the same
# YAML-parsing + Tier-D/allowlist logic a second time (Rust-first /
# no-new-duplicates, META-063/064).
#
# AC1: runs `chump preflight` and parses the CI workflow YAML.
# AC2: asserts every required CI check has a preflight mirror or an
#      explicit exemption (Tier-D in CI_GATES_INVENTORY.md, or an
#      allowlist entry in preflight-ci-parity-exceptions.txt).
# AC3: exit 0 on parity; non-zero with a diff report otherwise.
# AC4: wired into .github/workflows/ci-nightly.yml as a nightly smoke test.
#
# Bypass: delegated entirely to test-preflight-ci-parity.sh's own
# CHUMP_SKIP_PARITY_CHECK=1 escape hatch — not re-checked here, so this
# wrapper doesn't introduce a second bypass surface for the same gate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

if ! command -v chump >/dev/null 2>&1; then
    echo "[preflight-parity] FAIL: 'chump' binary not found on PATH" >&2
    exit 2
fi

echo "[preflight-parity] running 'chump preflight --help' to confirm the gate is live..."
if ! chump preflight --help >/tmp/preflight-parity-help.$$.log 2>&1; then
    echo "[preflight-parity] FAIL: 'chump preflight --help' exited non-zero" >&2
    cat /tmp/preflight-parity-help.$$.log >&2
    rm -f /tmp/preflight-parity-help.$$.log
    exit 2
fi
rm -f /tmp/preflight-parity-help.$$.log
echo "[preflight-parity] chump preflight is runnable."

echo "[preflight-parity] diffing CI workflow YAML gates against preflight mirrors..."
exec bash "$SCRIPT_DIR/test-preflight-ci-parity.sh"
