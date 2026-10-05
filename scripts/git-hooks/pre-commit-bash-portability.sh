#!/usr/bin/env bash
# pre-commit-bash-portability.sh — INFRA-2351 (META-269 sub-2)
#
# Thin wrapper that calls scripts/ci/bash-portability-lint.sh against staged
# scripts/**.sh files only (fast — a handful of files per commit, not the
# whole repo). Mirrors the pre-commit-css-token-discipline.sh pattern.
#
# No bypass env var (INFRA-2429 zero-bypass thesis) — add the offending
# file to scripts/ci/bash-portability-lint-allowlist.txt instead, same as
# every other lint gate in this repo.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

STAGED_SH=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '^scripts/.*\.sh$' || true)
if [[ -z "$STAGED_SH" ]]; then
    exit 0
fi

LINT="$REPO_ROOT/scripts/ci/bash-portability-lint.sh"
if [[ ! -x "$LINT" ]]; then
    echo "[bash-portability-lint] WARN: linter not found at $LINT, skipping." >&2
    exit 0
fi

mapfile -t files <<< "$STAGED_SH"
if bash "$LINT" "${files[@]}"; then
    exit 0
fi

echo "" >&2
echo "To exempt a file: add it to scripts/ci/bash-portability-lint-allowlist.txt." >&2
exit 1
