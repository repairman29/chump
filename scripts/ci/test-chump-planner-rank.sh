#!/usr/bin/env bash
# test-chump-planner-rank.sh — INFRA-1257
#
# Exercises chump-plan --format json against a synthetic gaps fixture.
# Asserts the output is valid JSON with the documented schema, and that
# the install-chump-planner-launchd.sh --once one-shot writes the
# canonical .chump-locks/gap-priority.json file.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== INFRA-1257 chump-plan + launchd installer tests ==="

# ── (a) Build chump-plan ─────────────────────────────────────────────────────
BIN="$REPO_ROOT/target/debug/chump-plan"
if [[ ! -x "$BIN" ]]; then
    echo "  building chump-plan..."
    (cd "$REPO_ROOT" && cargo build -p chump-planner --bin chump-plan 2>&1 | tail -3)
fi
[[ -x "$BIN" ]] && ok "chump-plan binary built at $BIN" || { fail "build failed"; exit 1; }

# ── (b) Synthetic fixtures: 3 gaps, one with a dependency ────────────────────
TMP="$(mktemp -d -t chump-plan-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
GAPS_DIR="$TMP/docs/gaps"
mkdir -p "$GAPS_DIR"

cat > "$GAPS_DIR/INFRA-9001.yaml" <<EOF
- id: INFRA-9001
  domain: INFRA
  title: synthetic P0 high-value
  status: open
  priority: P0
  effort: s
  acceptance_criteria:
    - test fixture
EOF

cat > "$GAPS_DIR/INFRA-9002.yaml" <<EOF
- id: INFRA-9002
  domain: INFRA
  title: synthetic P2 low-value
  status: open
  priority: P2
  effort: m
  acceptance_criteria:
    - test fixture
EOF

cat > "$GAPS_DIR/INFRA-9003.yaml" <<EOF
- id: INFRA-9003
  domain: INFRA
  title: synthetic P1 with prereq
  status: open
  priority: P1
  effort: xs
  depends_on: ["INFRA-9001"]
  acceptance_criteria:
    - test fixture
EOF

# ── (c) JSON output: valid + ranked correctly ────────────────────────────────
JSON="$TMP/out.json"
"$BIN" --gaps "$GAPS_DIR" --format json --agents 3 > "$JSON" 2>&1 || { fail "chump-plan exited non-zero"; cat "$JSON" >&2; exit 1; }

python3 -c "
import json, sys
data = json.load(open('$JSON'))
assert 'generated_at' in data, 'missing generated_at'
assert 'planner_version' in data, 'missing planner_version'
assert 'weights_identity' in data, 'missing weights_identity'
assert isinstance(data.get('items'), list), 'items must be list'
print(f'  fields ok; items={len(data[\"items\"])}')
" && ok "JSON output has documented schema" || fail "JSON schema check failed"

# Ranks: P0/s should outscore P2/m. P1 with open prereq should be filtered out
# of the default ranking (include_blocked=false).
python3 -c "
import json
data = json.load(open('$JSON'))
ids = [it['gap_id'] for it in data['items']]
print(f'  ranked ids: {ids}')
assert 'INFRA-9001' in ids, 'P0/s gap missing'
assert ids[0] == 'INFRA-9001', f'P0/s should be rank 1, got {ids[0]}'
# INFRA-9003 has depends_on INFRA-9001 still open — picker default excludes
assert 'INFRA-9003' not in ids, 'INFRA-9003 (blocked) should be excluded'
" && ok "ranking respects priority + prereq filter" || fail "ranking incorrect"

# ── (d) --include-blocked surfaces the blocked gap ──────────────────────────
JSON2="$TMP/out-blocked.json"
"$BIN" --gaps "$GAPS_DIR" --format json --agents 3 --include-blocked > "$JSON2" 2>&1
python3 -c "
import json
data = json.load(open('$JSON2'))
ids = [it['gap_id'] for it in data['items']]
assert 'INFRA-9003' in ids, f'--include-blocked should surface blocked gap; got {ids}'
" && ok "--include-blocked surfaces blocked gap" || fail "--include-blocked broken"

# ── (e) Launchd installer --once smoke ──────────────────────────────────────
INSTALLER="$REPO_ROOT/scripts/setup/install-chump-planner-launchd.sh"
[[ -x "$INSTALLER" ]] || chmod +x "$INSTALLER"
PRIO_FILE="$TMP/.chump-locks/gap-priority.json"
CHUMP_PLANNER_BIN="$BIN" \
CHUMP_PLANNER_REPO_ROOT="$TMP" \
  bash "$INSTALLER" --once 2>&1 | tail -3

if [[ -f "$PRIO_FILE" ]]; then
    ok "--once wrote $PRIO_FILE"
    python3 -c "import json; json.load(open('$PRIO_FILE'))" \
      && ok "gap-priority.json is valid JSON" \
      || fail "gap-priority.json is not valid JSON"
else
    # The installer wrote to the SCRIPT-resolved repo root (set via env);
    # under the synthetic fixture there are no gaps in docs/gaps/, so the
    # planner may have produced empty output. Check directly:
    ALT="$TMP/.chump-locks/gap-priority.json"
    if [[ -f "$ALT" ]]; then ok "--once wrote $ALT"; else fail "--once did not write priority file"; fi
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
