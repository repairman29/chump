#!/usr/bin/env bash
# generate-capabilities-registry.sh — INFRA-1729 (EFFECTIVE — Quartermaster ingest)
#
# Column A `chump ingest <repo-path>` Quartermaster artifact: produce
# <repo-path>/docs/CAPABILITIES_REGISTRY.json for an arbitrary repo.
#
# Thin wrapper over scripts/dev/build-capabilities-registry.sh; the underlying
# generator does all the work. This wrapper exists because the operator-facing
# entry point is "generate <thing> for <repo>", not "build the local one".
#
# Usage:
#   bash scripts/ops/generate-capabilities-registry.sh <repo-path> [--out PATH]
#
# Example (Column A demo):
#   bash scripts/ops/generate-capabilities-registry.sh /path/to/echeo
#   # → writes /path/to/echeo/docs/CAPABILITIES_REGISTRY.json
#
# Pillar: EFFECTIVE — feeds chump ingest's Quartermaster output.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <repo-path> [--out PATH]" >&2
    exit 2
fi

REPO_PATH="$1"; shift

if [[ ! -d "$REPO_PATH" ]]; then
    echo "[generate-capabilities-registry] not a directory: $REPO_PATH" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="$SCRIPT_DIR/../dev/build-capabilities-registry.sh"

if [[ ! -x "$BUILDER" ]]; then
    echo "[generate-capabilities-registry] missing builder: $BUILDER" >&2
    exit 2
fi

# Delegate; the builder accepts --repo-root and --out and handles defaults.
bash "$BUILDER" --repo-root "$REPO_PATH" "$@"
