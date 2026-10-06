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

# INFRA-8060: the ceiling declared in the shared scripts/dispatch/picker-policy.json (the
# file the Rust GapBriefing also loads) is the one the picker enforces — no env var.
echo "Test 4: ceiling from scripts/dispatch/picker-policy.json (no env) => enforced"
mkdir -p "$TMP/scripts/dispatch"
echo '{"sync_overhead_ceiling": 0.6}' >"$TMP/scripts/dispatch/picker-policy.json"
set +e
ERR="$(env -u SYNC_OVERHEAD_CEILING GAP_JSON_FILE="$TMP/gaps.json" CHUMP_REPO="$TMP" \
    SYNC_OVERHEAD_LOG_FILE="$TMP/log70.txt" python3 "$REPO_ROOT/scripts/dispatch/_pick_gap.py" 2>&1 >/dev/null)"
RC=$?
set -e
[[ $RC -eq 1 ]] && grep -q "exceeds ceiling 60%" <<<"$ERR" \
    || { echo "  FAIL rc=$RC err=$ERR"; exit 1; }
echo '{"sync_overhead_ceiling": 0.8}' >"$TMP/scripts/dispatch/picker-policy.json"
env -u SYNC_OVERHEAD_CEILING GAP_JSON_FILE="$TMP/gaps.json" CHUMP_REPO="$TMP" \
    SYNC_OVERHEAD_LOG_FILE="$TMP/log70.txt" python3 "$REPO_ROOT/scripts/dispatch/_pick_gap.py" >/dev/null 2>&1 \
    || { echo "  FAIL: 0.8 policy should not abort"; exit 1; }
echo "  PASS"

echo "Test 5: committed policy file is valid and declares the key"
python3 -c "import json; d=json.load(open('$REPO_ROOT/scripts/dispatch/picker-policy.json')); assert 'sync_overhead_ceiling' in d" \
    || { echo "  FAIL"; exit 1; }
echo "  PASS"
echo "All tests passed."
