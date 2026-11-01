#!/usr/bin/env bash
# Exec run-cloud-v2.py after loading repo-root .env (so TOGETHER_API_KEY and
# Anthropic keys set only in .env are visible without manually sourcing).
#
# Usage (from anywhere inside the repo):
#   bash scripts/ab-harness/run-cloud-v2-with-env.sh --fixture ... --tag ...
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PY="${PYTHON:-python3.12}"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

exec "$PY" "$ROOT/scripts/ab-harness/run-cloud-v2.py" "$@"
