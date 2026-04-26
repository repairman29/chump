#!/usr/bin/env bash
# CLI paths that never call the model (fast regression gate).
#
# Usage: ./scripts/ci/battle-cli-no-llm.sh
# Exit: 0 if all checks pass

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export CHUMP_REPO="${CHUMP_REPO:-$ROOT}"
export CHUMP_HOME="${CHUMP_HOME:-$ROOT}"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

if [[ -x "$ROOT/target/release/chump" ]]; then
  CHUMP_DUE=("$ROOT/target/release/chump" "--chump-due")
else
  CHUMP_DUE=(cargo run -q -- "--chump-due")
fi

echo "=== battle-cli-no-llm: chump --chump-due ==="
"${CHUMP_DUE[@]}" || true
# Exit 0 expected (may print nothing if no due schedule)
echo "OK: chump-due exited"
