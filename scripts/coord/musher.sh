#!/usr/bin/env bash
# musher.sh — thin wrapper around musher.py (bash 3 compatible)
#
# Usage:
#   scripts/coord/musher.sh --pick
#   scripts/coord/musher.sh --check <GAP-ID>
#   scripts/coord/musher.sh --assign <N>
#   scripts/coord/musher.sh --status
#   scripts/coord/musher.sh --why <GAP-ID>

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"

PYTHON="${PYTHON:-python3.12}"
if ! "$PYTHON" -c "import sys; assert sys.version_info >= (3,9)" 2>/dev/null; then
    PYTHON=python3
fi

exec "$PYTHON" "$SCRIPT_DIR/musher.py" "$@"
