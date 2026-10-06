#!/usr/bin/env bash
# CREDIBLE-1489: CI gate — fail when a done/superseded gap's closed_pr does not
# reference the gap (or predates it). Skips (exit 0) when there is no chump
# binary or no local PR cache to check against: unverifiable is not a failure.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if ! command -v chump >/dev/null 2>&1 && [[ -z "${CHUMP_BIN:-}" ]]; then
    echo "SKIP: chump binary not found"; exit 0
fi
[[ -f .chump/github_cache.db ]] || { echo "SKIP: no .chump/github_cache.db PR cache"; exit 0; }
PATH="$(dirname "${CHUMP_BIN:-$(command -v chump)}"):$PATH" \
    exec python3 scripts/ops/closed-pr-integrity-check.py --strict
