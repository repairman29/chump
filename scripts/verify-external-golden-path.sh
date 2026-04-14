#!/usr/bin/env bash
# Non-interactive checks for the external golden path (CI / maintainer smoke).
# Does not start Ollama or the web server. Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "== verify-external-golden-path: repo=$ROOT =="
command -v cargo >/dev/null || { echo "FAIL: cargo not in PATH"; exit 1; }
cargo build -q
echo "OK: cargo build"
test -f scripts/setup-local.sh || { echo "FAIL: setup-local.sh missing"; exit 1; }
test -f docs/EXTERNAL_GOLDEN_PATH.md || { echo "FAIL: EXTERNAL_GOLDEN_PATH.md missing"; exit 1; }
test -f run-web.sh || { echo "FAIL: run-web.sh missing"; exit 1; }
echo "OK: golden path artifacts present"
echo "== repo metrics (paste into reviews; see docs/PRODUCT_REALITY_CHECK.md) =="
bash "$ROOT/scripts/print-repo-metrics.sh" || true
echo "Done. (Start Ollama + ./run-web.sh for full manual path.)"
echo "Optional timing log: ./scripts/golden-path-timing.sh (see docs/EXTERNAL_GOLDEN_PATH.md)"
