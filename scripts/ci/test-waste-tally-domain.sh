#!/usr/bin/env bash
# test-waste-tally-domain.sh — INFRA-934
#
# Tests for `chump waste-tally --domain`:
#   1. Table output contains required columns (domain, gaps_run, tokens_est, pct)
#   2. --json output contains required fields
#   3. exit non-zero when a domain exceeds 40% of token budget
#   4. exit 0 when no domain exceeds 40%
#   5. --domain alias works (same as --by-domain)
#   6. JSON domains sorted by pct_of_total descending

set -uo pipefail

PASS=0; FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP="${REPO_ROOT}/target/debug/chump"

if [[ ! -x "$CHUMP" ]]; then
    echo "SKIP: chump binary not found at $CHUMP — run 'cargo build --bin chump' first"
    exit 0
fi

echo "=== INFRA-934 waste-tally --domain tests ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMBIENT="$TMP/ambient.jsonl"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Fixture: 2 INFRA sessions (800k tokens, 80%) + 1 FLEET session (200k, 20%) ──
python3 - "$AMBIENT" "$NOW" <<'PYEOF'
import json, sys
path, now = sys.argv[1], sys.argv[2]
events = [
    {"ts": now, "kind": "session_end", "gap_id": "INFRA-100",
     "session_id": "s1", "outcome": "shipped",
     "input_tokens": 400000, "output_tokens": 350000, "cache_read_tokens": 50000,
     "model": "claude-haiku-4-5"},
    {"ts": now, "kind": "session_end", "gap_id": "INFRA-101",
     "session_id": "s2", "outcome": "shipped",
     "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0,
     "model": "claude-haiku-4-5"},
    {"ts": now, "kind": "session_end", "gap_id": "FLEET-50",
     "session_id": "s3", "outcome": "shipped",
     "input_tokens": 100000, "output_tokens": 80000, "cache_read_tokens": 20000,
     "model": "claude-haiku-4-5"},
]
with open(path, "w") as f:
    for ev in events:
        f.write(json.dumps(ev, separators=(',', ':')) + "\n")
PYEOF

# ── 1. Table output — required columns ────────────────────────────────────
echo "[1. Table output — required columns present]"
TABLE=$(CHUMP_AMBIENT_LOG="$AMBIENT" "$CHUMP" waste-tally --domain --since 1h 2>/dev/null || true)
for col in "domain|DOMAIN" "gaps_run" "tokens_est" "pct|%"; do
    label="${col//|*/}"
    if echo "$TABLE" | grep -qE "$col"; then
        ok "table contains '$label' column"
    else
        fail "table missing '$label' column"
    fi
done

# ── 2. --json output — required fields ────────────────────────────────────
echo
echo "[2. --json output — required fields]"
JSON=$(CHUMP_AMBIENT_LOG="$AMBIENT" "$CHUMP" waste-tally --domain --since 1h --json 2>/dev/null || true)
if echo "$JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert 'domains' in d" 2>/dev/null; then
    ok "--json has 'domains' key"
else
    fail "--json missing 'domains' key"
fi
if echo "$JSON" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
dom = d['domains'][0] if d['domains'] else {}
assert 'gaps_run' in dom, 'missing gaps_run'
assert 'tokens_est' in dom, 'missing tokens_est'
assert 'pct_of_total' in dom, 'missing pct_of_total'
" 2>/dev/null; then
    ok "--json domain entries have gaps_run, tokens_est, pct_of_total"
else
    fail "--json domain entries missing required fields"
fi
if echo "$JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert 'has_breach' in d" 2>/dev/null; then
    ok "--json has 'has_breach' key"
else
    fail "--json missing 'has_breach' key"
fi

# ── 3. Exit non-zero when domain exceeds 40% ──────────────────────────────
echo
echo "[3. Exit non-zero on 40% breach]"
set +e
CHUMP_AMBIENT_LOG="$AMBIENT" "$CHUMP" waste-tally --domain --since 1h >/dev/null 2>&1
BREACH_EXIT=$?
set -e
if [[ "$BREACH_EXIT" -ne 0 ]]; then
    ok "exit $BREACH_EXIT (non-zero) when INFRA has ~80% of tokens"
else
    fail "exit 0 when INFRA exceeds 40% — expected non-zero"
fi

# ── 4. Exit 0 when no domain exceeds 40% ──────────────────────────────────
echo
echo "[4. Exit 0 when no breach]"
BALANCED="$TMP/balanced.jsonl"
python3 - "$BALANCED" "$NOW" <<'PYEOF'
import json, sys
path, now = sys.argv[1], sys.argv[2]
for domain, gap in [("INFRA","INFRA-1"),("FLEET","FLEET-1"),("COG","COG-1"),("PRODUCT","PRODUCT-1")]:
    ev = {"ts": now, "kind": "session_end", "gap_id": gap,
          "session_id": f"s-{domain}", "outcome": "shipped",
          "input_tokens": 25000, "output_tokens": 0, "cache_read_tokens": 0,
          "model": "claude-haiku-4-5"}
    open(path, "a").write(json.dumps(ev, separators=(',', ':')) + "\n")
PYEOF
set +e
CHUMP_AMBIENT_LOG="$BALANCED" "$CHUMP" waste-tally --domain --since 1h >/dev/null 2>&1
BALANCED_EXIT=$?
set -e
if [[ "$BALANCED_EXIT" -eq 0 ]]; then
    ok "exit 0 when no domain exceeds 40% (4 domains at 25% each)"
else
    fail "exit $BALANCED_EXIT — expected 0 when no breach"
fi

# ── 5. --domain alias matches --by-domain ─────────────────────────────────
echo
echo "[5. --domain alias matches --by-domain]"
OUT_DOMAIN=$(CHUMP_AMBIENT_LOG="$AMBIENT" "$CHUMP" waste-tally --domain --since 1h 2>/dev/null || true)
OUT_BY_DOMAIN=$(CHUMP_AMBIENT_LOG="$AMBIENT" "$CHUMP" waste-tally --by-domain --since 1h 2>/dev/null || true)
if [[ "$OUT_DOMAIN" == "$OUT_BY_DOMAIN" ]]; then
    ok "--domain and --by-domain produce identical output"
else
    fail "--domain and --by-domain output differs"
fi

# ── 6. JSON sorted by pct_of_total descending ─────────────────────────────
echo
echo "[6. JSON domains sorted by pct_of_total descending]"
SORTED=$(CHUMP_AMBIENT_LOG="$AMBIENT" "$CHUMP" waste-tally --domain --since 1h --json 2>/dev/null || true)
if echo "$SORTED" | python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
pcts = [dom['pct_of_total'] for dom in d['domains']]
assert pcts == sorted(pcts, reverse=True), f'not sorted: {pcts}'
" 2>/dev/null; then
    ok "domains sorted by pct_of_total descending"
else
    fail "domains not sorted by pct_of_total descending"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
