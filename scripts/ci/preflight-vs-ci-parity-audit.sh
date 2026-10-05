#!/usr/bin/env bash
# preflight-vs-ci-parity-audit.sh — INFRA-2084 AC1
#
# Human-facing inventory report: lists (a) CI gates present in
# .github/workflows/ci.yml + siblings, (b) gates currently mirrored in
# `chump preflight`, (c) DELTA — gates in CI but not in preflight (and not
# Tier-D / allowlisted).
#
# This is a REPORT, not a gate — it always exits 0 so it can be run freely
# during gap decomposition / coverage audits. The pass/fail authority is
# scripts/ci/test-preflight-ci-parity.sh (wired into the fast-checks CI
# shard); this script reuses that same classification engine in report
# mode (CHUMP_PARITY_REPORT=1) so the inventory never drifts from what the
# gate actually enforces.
#
# Usage: bash scripts/ci/preflight-vs-ci-parity-audit.sh [--json]
#   --json  emit machine-parseable JSON only (INFRA-5205 AC3), no prose report

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--json" ]]; then
    CHUMP_PARITY_REPORT=1 CHUMP_PARITY_JSON=1 bash "$SCRIPT_DIR/test-preflight-ci-parity.sh" 2>/dev/null \
        | sed -n 's/^CHUMP_PARITY_JSON_LINE://p'
    exit 0
fi

CHUMP_PARITY_REPORT=1 bash "$SCRIPT_DIR/test-preflight-ci-parity.sh"
exit 0
