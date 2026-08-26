#!/usr/bin/env bash
# test-style-loader.sh — EFFECTIVE-484
#
# Type-checks + unit-tests web/v2/lib/style/loader.ts (the content/STYLE.md
# loader that applies Jeff's voice rules to publisher drafts before they
# reach the EFFECTIVE-365 approval queue).
#
# Exit: 0 = typecheck + all tests pass
#       1 = typecheck failed or a test failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
STYLE_DIR="$REPO_ROOT/web/v2/lib/style"

cd "$STYLE_DIR"

if [ ! -d node_modules ]; then
  npm ci --silent
fi

npm run --silent typecheck
npm test --silent
