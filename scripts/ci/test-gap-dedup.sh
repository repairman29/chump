#!/usr/bin/env bash
# test-gap-dedup.sh — INFRA-881
#
# Validates scripts/ops/gap-dedup-check.sh using synthetic gap title fixtures.
# The fake `chump` binary injects controlled JSON into the gap-list path.
#
#  1. Script exists and is executable
#  2. Exact duplicate titles → similarity 1.0 (detected at 0.85)
#  3. Near-duplicate titles (one is a strict superset of the other) → caught at 0.85
#  4. Clearly distinct gaps → not flagged at 0.85
#  5. --json output is a valid JSON array
#  6. --json output contains keep_id, close_id, similarity, keep_title, close_title
#  7. Keeps higher-priority gap (lower P number), closes lower-priority
#  8. Equal priority → keeps newer (higher created_at)
#  9. --dry-run with --apply: prints intent, does not call chump gap ship
# 10. --threshold 0.50 catches more pairs than 0.85
# 11. --threshold 0.99 catches only near-exact matches

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/gap-dedup-check.sh"

echo "=== INFRA-881 gap-dedup test ==="
echo

# ── 1. Script exists and is executable ────────────────────────────────────────
echo "[1. script exists and is executable]"
if [[ -x "$SCRIPT" ]]; then
    ok "gap-dedup-check.sh exists and is executable"
else
    fail "gap-dedup-check.sh missing or not executable"
    exit 1
fi

# ── Setup: fake chump binary injected into PATH ───────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_CHUMP="$TMP/chump"
FAKE_GAPS_FILE="$TMP/gaps.json"
SHIP_LOG="$TMP/ship_calls.log"
touch "$SHIP_LOG"

make_fake_chump() {
    cat > "$FAKE_CHUMP" <<SHEOF
#!/usr/bin/env bash
if [[ "\$*" == "gap list --status open --json" ]]; then
    cat "$FAKE_GAPS_FILE"; exit 0
fi
if [[ "\$*" == gap\ ship* ]]; then echo "\$*" >> "$SHIP_LOG"; fi
exit 0
SHEOF
    chmod +x "$FAKE_CHUMP"
}
make_fake_chump

ORIG_PATH="$PATH"
export PATH="$TMP:$PATH"
export FAKE_GAPS_FILE

write_gaps() { printf '%s\n' "$1" > "$FAKE_GAPS_FILE"; }
run_dedup()  { bash "$SCRIPT" "${@}" 2>/dev/null; }
count_pairs(){ python3 -c "import json; print(len(json.loads(r'''$1''')))" 2>/dev/null || echo 0; }

# High-similarity fixture: b is a + one extra word (sim ~0.89 with 3 docs)
BASE="RESILIENT: fleet worker crash restart recovery detection"
NEAR="RESILIENT: fleet worker crash restart recovery detection system"
DIST="EFFECTIVE: OAuth2 Google login provider completely unique different"

# ── 2. Exact duplicate titles → detected at 0.85 ─────────────────────────────
echo
echo "[2. exact duplicate titles → detected]"
write_gaps "[
  {\"id\":\"INFRA-100\",\"title\":\"$BASE\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"s\",\"created_at\":1000},
  {\"id\":\"INFRA-101\",\"title\":\"$BASE\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"s\",\"created_at\":999}
]"
OUT=$(run_dedup --json --threshold 0.85)
COUNT=$(count_pairs "$OUT")
if [[ "$COUNT" -ge 1 ]]; then
    ok "exact duplicate detected (count=$COUNT)"
else
    fail "exact duplicate not detected (got: $OUT)"
fi

# ── 3. Near-duplicate titles → caught at 0.85 ────────────────────────────────
echo
echo "[3. near-duplicate (superset title) → caught at 0.85]"
write_gaps "[
  {\"id\":\"INFRA-200\",\"title\":\"$BASE\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":1000},
  {\"id\":\"INFRA-201\",\"title\":\"$NEAR\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":999},
  {\"id\":\"INFRA-202\",\"title\":\"$DIST\",\"status\":\"open\",\"priority\":\"P2\",\"effort\":\"s\",\"created_at\":1001}
]"
OUT=$(run_dedup --json --threshold 0.85)
COUNT=$(count_pairs "$OUT")
if [[ "$COUNT" -ge 1 ]]; then
    ok "near-duplicate caught at 0.85 (count=$COUNT)"
else
    fail "near-duplicate not caught at 0.85 (got: $OUT)"
fi

# ── 4. Clearly distinct gaps → not flagged at 0.85 ───────────────────────────
echo
echo "[4. clearly distinct gaps → not flagged]"
write_gaps "[
  {\"id\":\"INFRA-300\",\"title\":\"EFFECTIVE: OAuth2 login Google provider integration\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":1000},
  {\"id\":\"INFRA-301\",\"title\":\"ZERO-WASTE: prune stale worktrees older than seven days\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"s\",\"created_at\":999},
  {\"id\":\"INFRA-302\",\"title\":\"CREDIBLE: emit KPI event on every gap ship operation\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"s\",\"created_at\":1001}
]"
OUT=$(run_dedup --json --threshold 0.85)
COUNT=$(count_pairs "$OUT")
if [[ "$COUNT" -eq 0 ]]; then
    ok "distinct gaps not flagged"
else
    fail "unexpected detection in distinct gaps (count=$COUNT, got: $OUT)"
fi

# ── 5. --json output is a valid JSON array ────────────────────────────────────
echo
echo "[5. --json output is valid JSON array]"
write_gaps "[
  {\"id\":\"INFRA-400\",\"title\":\"$BASE\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":1000},
  {\"id\":\"INFRA-401\",\"title\":\"$NEAR\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":999}
]"
OUT=$(run_dedup --json)
if python3 -c "import json; data=json.loads(r'''$OUT'''); assert isinstance(data, list)" 2>/dev/null; then
    ok "--json output is a valid JSON array"
else
    fail "--json output not valid JSON (got: $OUT)"
fi

# ── 6. --json output contains required fields ─────────────────────────────────
echo
echo "[6. --json output has keep_id, close_id, similarity, keep_title, close_title]"
write_gaps "[
  {\"id\":\"INFRA-400\",\"title\":\"$BASE\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":1000},
  {\"id\":\"INFRA-401\",\"title\":\"$NEAR\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":999}
]"
OUT=$(run_dedup --json --threshold 0.85)
if python3 -c "
import json
data = json.loads(r'''$OUT''')
assert len(data) > 0, 'no pairs found'
e = data[0]
for field in ('keep_id','close_id','similarity','keep_title','close_title'):
    assert field in e, f'missing {field}: {e}'
assert 0 < e['similarity'] <= 1.0, f'similarity={e[\"similarity\"]}'
" 2>/dev/null; then
    ok "--json has keep_id, close_id, similarity, keep_title, close_title"
else
    fail "--json missing required fields (got: $OUT)"
fi

# ── 7. Keeps higher-priority gap (P0 over P2) ────────────────────────────────
echo
echo "[7. keeps higher-priority (P0 over P2) gap]"
write_gaps "[
  {\"id\":\"INFRA-500\",\"title\":\"$BASE\",\"status\":\"open\",\"priority\":\"P0\",\"effort\":\"m\",\"created_at\":1000},
  {\"id\":\"INFRA-501\",\"title\":\"$NEAR\",\"status\":\"open\",\"priority\":\"P2\",\"effort\":\"m\",\"created_at\":999}
]"
OUT=$(run_dedup --json --threshold 0.85)
if python3 -c "
import json
data = json.loads(r'''$OUT''')
assert len(data) > 0, 'no pairs found'
e = data[0]
assert e['keep_id'] == 'INFRA-500', f'P0 should be kept, got keep={e[\"keep_id\"]}'
assert e['close_id'] == 'INFRA-501', f'P2 should be closed, got close={e[\"close_id\"]}'
" 2>/dev/null; then
    ok "P0 gap kept, P2 gap marked for close"
else
    fail "priority handling wrong (got: $OUT)"
fi

# ── 8. Equal priority → keep newer (higher created_at) ───────────────────────
echo
echo "[8. equal priority → keeps newer (higher created_at)]"
write_gaps "[
  {\"id\":\"INFRA-600\",\"title\":\"$BASE\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":500},
  {\"id\":\"INFRA-601\",\"title\":\"$NEAR\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":999}
]"
OUT=$(run_dedup --json --threshold 0.85)
if python3 -c "
import json
data = json.loads(r'''$OUT''')
assert len(data) > 0, 'no pairs found'
e = data[0]
assert e['keep_id'] == 'INFRA-601', f'newer gap should be kept, got keep={e[\"keep_id\"]}'
assert e['close_id'] == 'INFRA-600', f'older gap should be closed, got close={e[\"close_id\"]}'
" 2>/dev/null; then
    ok "newer gap kept when priorities equal"
else
    fail "tie-breaking wrong (got: $OUT)"
fi

# ── 9. --dry-run with --apply: prints intent, doesn't call chump gap ship ─────
echo
echo "[9. --dry-run with --apply: no actual close]"
write_gaps "[
  {\"id\":\"INFRA-700\",\"title\":\"$BASE\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":1000},
  {\"id\":\"INFRA-701\",\"title\":\"$NEAR\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":999}
]"
> "$SHIP_LOG"
DRY_OUT=$(run_dedup --apply --dry-run --threshold 0.85)
SHIP_CALLS=$(cat "$SHIP_LOG" 2>/dev/null | wc -l | tr -d ' ')
if echo "$DRY_OUT" | grep -q "dry-run" && [[ "$SHIP_CALLS" -eq 0 ]]; then
    ok "--dry-run printed intent without calling gap ship"
else
    fail "--dry-run failed (ship_calls=$SHIP_CALLS, out: $DRY_OUT)"
fi

# ── 10. --threshold 0.50 catches more pairs than 0.85 ────────────────────────
echo
echo "[10. --threshold 0.50 catches more pairs than 0.85]"
write_gaps "[
  {\"id\":\"INFRA-800\",\"title\":\"RESILIENT: fleet crash restart\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":1000},
  {\"id\":\"INFRA-801\",\"title\":\"RESILIENT: fleet workers crash restart auto\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":999},
  {\"id\":\"INFRA-802\",\"title\":\"CREDIBLE: metrics fleet dashboard reporting\",\"status\":\"open\",\"priority\":\"P2\",\"effort\":\"s\",\"created_at\":1001},
  {\"id\":\"INFRA-803\",\"title\":\"CREDIBLE: fleet health metrics reporting system\",\"status\":\"open\",\"priority\":\"P2\",\"effort\":\"s\",\"created_at\":1002}
]"
OUT_85=$(run_dedup --json --threshold 0.85)
OUT_50=$(run_dedup --json --threshold 0.50)
COUNT_85=$(count_pairs "$OUT_85")
COUNT_50=$(count_pairs "$OUT_50")
if [[ "$COUNT_50" -ge "$COUNT_85" ]]; then
    ok "lower threshold catches >= pairs (0.50=$COUNT_50, 0.85=$COUNT_85)"
else
    fail "lower threshold should catch >= pairs (0.50=$COUNT_50, 0.85=$COUNT_85)"
fi

# ── 11. --threshold 0.99 catches fewer pairs than 0.85 ───────────────────────
echo
echo "[11. --threshold 0.99 catches <= pairs than 0.85]"
write_gaps "[
  {\"id\":\"INFRA-900\",\"title\":\"$BASE\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":1000},
  {\"id\":\"INFRA-901\",\"title\":\"$NEAR\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":999},
  {\"id\":\"INFRA-902\",\"title\":\"EFFECTIVE: OAuth2 login GitHub provider integration\",\"status\":\"open\",\"priority\":\"P1\",\"effort\":\"m\",\"created_at\":1001}
]"
OUT_85=$(run_dedup --json --threshold 0.85)
OUT_99=$(run_dedup --json --threshold 0.99)
COUNT_85=$(count_pairs "$OUT_85")
COUNT_99=$(count_pairs "$OUT_99")
if [[ "$COUNT_99" -le "$COUNT_85" ]]; then
    ok "higher threshold catches <= pairs (0.99=$COUNT_99, 0.85=$COUNT_85)"
else
    fail "higher threshold should catch <= pairs (0.99=$COUNT_99, 0.85=$COUNT_85)"
fi

export PATH="$ORIG_PATH"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
