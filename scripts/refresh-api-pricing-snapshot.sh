#!/usr/bin/env bash
# Refresh docs/API_PRICING_SNAPSHOT.md via Tavily (TAVILY_API_KEY).
# See docs/API_PRICING_MAINTENANCE.md

set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PY="${PYTHON:-python3.12}"
if ! command -v "$PY" >/dev/null 2>&1; then
    PY=python3
fi

if [[ -z "${TAVILY_API_KEY:-}" ]]; then
    echo "[refresh-api-pricing-snapshot] TAVILY_API_KEY not set — skip." >&2
    echo "  Set the key (same as Chump web_search) and re-run." >&2
    echo "  See docs/API_PRICING_MAINTENANCE.md" >&2
    exit 0
fi

"$PY" scripts/refresh_api_pricing_snapshot.py docs/API_PRICING_SNAPSHOT.md
