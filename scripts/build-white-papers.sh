#!/usr/bin/env bash
# Build PDF white papers from docs/white-paper-manifest.json (see script body in build-white-papers.py).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/build-white-papers.py" "$@"
