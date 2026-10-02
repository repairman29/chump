#!/usr/bin/env bash
# test-rules-registry-coverage.sh — ZERO-WASTE-125 AC1
#
# Fails when docs/process/RULE_REGISTRY.json is stale relative to the git
# hooks + CI test gates actually on disk — i.e. someone added a new gate
# without regenerating the registry. Regenerating is mechanical and free
# (scripts/coord/rules-registry-gen.sh), so staleness always means "forgot
# to run the generator," never a real tradeoff.
#
# Usage: scripts/ci/test-rules-registry-coverage.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="docs/process/RULE_REGISTRY.json"

if [[ ! -f "$REGISTRY" ]]; then
    echo "FAIL: $REGISTRY missing — run scripts/coord/rules-registry-gen.sh"
    exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
bash scripts/coord/rules-registry-gen.sh --out "$TMP" >/dev/null

if ! diff -q "$REGISTRY" "$TMP" >/dev/null 2>&1; then
    echo "FAIL: $REGISTRY is stale — a git hook or scripts/ci/test-*.sh gate"
    echo "  landed (or was removed) without regenerating the registry."
    echo "  Fix: bash scripts/coord/rules-registry-gen.sh && git add $REGISTRY"
    diff "$REGISTRY" "$TMP" || true
    exit 1
fi

echo "OK: $REGISTRY matches on-disk gates"
