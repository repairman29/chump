#!/usr/bin/env bash
# generate-hidden-gems.sh — INFRA-1783 (EFFECTIVE — Evangelist ingest)
#
# Column A `chump ingest <repo-path>` Phase 3 Evangelist artifact: produce
# <repo-path>/docs/HIDDEN_GEMS.md for an arbitrary repo.
#
# Thin wrapper over scripts/dev/build-hidden-gems.sh; the underlying
# generator does all the work. This wrapper exists because the operator-facing
# entry point is "generate <thing> for <repo>", not "build the local one".
# Sibling of scripts/ops/generate-capabilities-registry.sh (Phase 4 Systematizer).
#
# Usage:
#   bash scripts/ops/generate-hidden-gems.sh <repo-path> [--out PATH]
#
# Example (Column A demo):
#   bash scripts/ops/generate-hidden-gems.sh /path/to/echeo
#   # → writes /path/to/echeo/docs/HIDDEN_GEMS.md
#
# Pillar: EFFECTIVE — feeds chump ingest's Evangelist output.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <repo-path> [--out PATH]" >&2
    exit 2
fi

REPO_PATH="$1"; shift

if [[ ! -d "$REPO_PATH" ]]; then
    echo "[generate-hidden-gems] not a directory: $REPO_PATH" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="$SCRIPT_DIR/../dev/build-hidden-gems.sh"

if [[ ! -x "$BUILDER" ]]; then
    echo "[generate-hidden-gems] missing builder: $BUILDER" >&2
    exit 2
fi

# Delegate; the builder accepts --repo-root and --out and handles defaults.
bash "$BUILDER" --repo-root "$REPO_PATH" "$@"
