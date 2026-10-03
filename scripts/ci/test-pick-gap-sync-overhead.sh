#!/usr/bin/env bash
# test-pick-gap-sync-overhead.sh — CREDIBLE-167
# _pick_gap.py must exit 1 with a stderr warning when automated coherence
# syncs exceed SYNC_OVERHEAD_CEILING of the last 50 commits, and not otherwise.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo '[]' >"$TMP/gaps.json"
{ for i in $(seq 1 35); do echo "chore(backlog): coherence sync — $i gaps closed"; done
  for i in $(seq 1 15); do echo "real work $i"; done; } >"$TMP/log70.txt"

echo "Test 1: 70% syncs vs 0.6 ceiling => exit 1 + warning"
set +e
ERR="$(GAP_JSON_FILE="$TMP/gaps.json" CHUMP_REPO="$TMP" SYNC_OVERHEAD_CEILING=0.6 \
    SYNC_OVERHEAD_LOG_FILE="$TMP/log70.txt" python3 "$REPO_ROOT/scripts/dispatch/_pick_gap.py" 2>&1 >/dev/null)"
RC=$?
set -e
[[ $RC -eq 1 ]] && grep -q "Sync overhead 70% exceeds ceiling 60%" <<<"$ERR" \
    || { echo "  FAIL rc=$RC err=$ERR"; exit 1; }
echo "  PASS"

echo "Test 2: under ceiling => no abort"
GAP_JSON_FILE="$TMP/gaps.json" CHUMP_REPO="$TMP" SYNC_OVERHEAD_CEILING=0.8 \
    SYNC_OVERHEAD_LOG_FILE="$TMP/log70.txt" python3 "$REPO_ROOT/scripts/dispatch/_pick_gap.py" >/dev/null 2>&1 \
    || { echo "  FAIL: unexpected nonzero exit"; exit 1; }
echo "  PASS"

echo "Test 3: ceiling unset => no abort"
GAP_JSON_FILE="$TMP/gaps.json" CHUMP_REPO="$TMP" SYNC_OVERHEAD_LOG_FILE="$TMP/log70.txt" \
    python3 "$REPO_ROOT/scripts/dispatch/_pick_gap.py" >/dev/null 2>&1 \
    || { echo "  FAIL"; exit 1; }
echo "  PASS"
echo "All tests passed."
