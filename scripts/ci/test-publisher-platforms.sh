#!/usr/bin/env bash
# test-publisher-platforms.sh — EFFECTIVE-483
#
# Type-checks + unit-tests web/v2/lib/publisher/platforms.ts (the typed
# PUBLISHER_PLATFORMS config codifying PUBLISHER.md's platform boundaries).
#
# Exit: 0 = typecheck + all tests pass
#       1 = typecheck failed or a test failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PUBLISHER_DIR="$REPO_ROOT/web/v2/lib/publisher"

cd "$PUBLISHER_DIR"

if [ ! -d node_modules ]; then
  npm ci --silent
fi

npm run --silent typecheck
npm test --silent
