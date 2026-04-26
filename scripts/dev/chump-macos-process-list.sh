#!/usr/bin/env bash
# List Chump / Cowork-related processes on macOS (audit duplicates after Dock reopen issues).
set -euo pipefail
echo "== chump-desktop =="
pgrep -fl chump-desktop 2>/dev/null || echo "(none)"
echo ""
echo "== chump --web (heuristic) =="
ps aux | grep '[c]hump' | grep -- '--web' || echo "(none)"
echo ""
echo "Tip: With a current Chump.app build, only one desktop shell should run; reopening the Dock icon focuses the existing window."
echo "Stop extras: quit from the Dock, or: killall chump-desktop"
echo "Sidecar only: pkill -f 'chump --web'   # only if you intend to stop the local web engine"
