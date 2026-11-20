#!/usr/bin/env bash
# CI gate for CREDIBLE-297: outcomes-delivered.sh must treat a bot-merge
# event with exit_code 13 (inline clippy-exit) as a landed outcome, ignoring
# any wait_expiry field, so trek/swe no longer reports FAILED for PRs that
# actually merged.
set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/outcomes-delivered.sh"

echo "=== CREDIBLE-297: outcomes-delivered.sh exit_code 13 handling ==="
echo

if [[ ! -f "$SCRIPT" ]]; then
  fail "CREDIBLE-297: $SCRIPT not found"
  echo
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── AC#1: count_json_events counts a bot-merge/exit_code:13 line as success ──
FIXTURE="$TMP/clippy-exit-13.jsonl"
cat > "$FIXTURE" <<'EOF'
{"ts":"2026-08-22T23:04:00Z","type":"bot-merge","exit_code":13,"wait_expiry":true,"note":"clippy lint errors"}
EOF

# shellcheck disable=SC1090
source "$SCRIPT"
count="$(count_json_events "$FIXTURE")"
if [[ "$count" -ge 1 ]]; then
  ok "count_json_events returns >=1 for bot-merge exit_code:13 (got $count)"
else
  fail "count_json_events returned $count for bot-merge exit_code:13 (expected >=1)"
fi

# ── AC#2: running the script on the fixture exits 0 and prints SUCCESS ──────
out="$("$SCRIPT" "$FIXTURE" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "SUCCESS" <<<"$out"; then
  ok "script exits 0 and prints SUCCESS for bot-merge exit_code:13 fixture"
else
  fail "script exit=$rc output='$out' (expected exit 0 + SUCCESS)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
