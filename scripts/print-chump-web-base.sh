#!/usr/bin/env bash
# Print the resolved Chump PWA base URL (same rules as run-ui-e2e.sh). For curl / manual checks.
# Usage: from repo root: ./scripts/print-chump-web-base.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env"
  set +a
fi
# shellcheck source=scripts/lib/chump-web-base.sh
source "$ROOT/scripts/lib/chump-web-base.sh"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
chump_resolve_e2e_base_url
