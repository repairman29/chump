#!/usr/bin/env bash
# test-pick-gap-skips-shipped.sh — FLEET-040 regression test.
#
# Verifies _pick_gap.py skips a candidate gap when origin/main's
# docs/gaps/<ID>.yaml already says status:done — even if the local
# state.db (the GAP_JSON_FILE input) still says open.
#
# Pre-fix: state.db lag vs origin/main → worker re-picks gaps that
# landed via PR but haven't been re-imported. Wasted FLEET_TIMEOUT_S
# of Haiku per retry (worker 6 hit INFRA-310 6× pre-fix).
#
# 4 cases:
#   1. gap on origin/main as status:done → picker skips it
#   2. gap on origin/main as status:open → picker picks it
#   3. gap not in origin/main yet (newly reserved) → picker picks it
#   4. FLEET_SKIP_SHIPPED_CHECK=0 bypass → picker doesn't check, picks anyway

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_gap.py"

[[ -f "$PICKER" ]] || { echo "[FAIL] $PICKER missing"; exit 1; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# Stand up a fake "main" repo with two YAML mirrors:
#   docs/gaps/INFRA-9001.yaml  status: done
#   docs/gaps/INFRA-9002.yaml  status: open
# (no docs/gaps/INFRA-9003.yaml — represents a gap newly reserved
# but not yet reflected on origin/main.)
mkdir -p "$TMP/origin.git" && cd "$TMP/origin.git" && git init --bare -q
cd "$TMP" && git clone -q origin.git work
cd work
git config user.email t@t && git config user.name t
mkdir -p docs/gaps
cat > docs/gaps/INFRA-9001.yaml <<'EOF'
- id: INFRA-9001
  domain: INFRA
  title: shipped on main
  status: done
  priority: P1
  effort: xs
EOF
cat > docs/gaps/INFRA-9002.yaml <<'EOF'
- id: INFRA-9002
  domain: INFRA
  title: open on main
  status: open
  priority: P1
  effort: xs
EOF
git add docs/gaps/ && git commit -qm "fixture"
git push -q origin HEAD:main

# The picker reads candidates from a JSON file (state.db dump). We
# include all 3 gaps as "open" — simulating the state.db-lags-main
# scenario.
cat > "$TMP/gaps.json" <<'JSON'
[
  {"id":"INFRA-9001","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1000,"depends_on":""},
  {"id":"INFRA-9002","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1001,"depends_on":""},
  {"id":"INFRA-9003","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1002,"depends_on":""}
]
JSON

# Need origin/main fetched (the work clone has it via clone).
cd "$TMP/work"
git fetch origin main --quiet

run_picker() {
    env GAP_JSON_FILE="$TMP/gaps.json" \
        FLEET_PRIORITY_FILTER="P1" \
        FLEET_DOMAIN_FILTER="INFRA" \
        FLEET_EFFORT_FILTER="xs" \
        EXCLUDE_RE="^(EVAL-|RESEARCH-|META-)" \
        ACTIVE_GAPS="" \
        WORKER_INDEX="1" \
        REPO_ROOT="$TMP/work" \
        "$@" \
        python3 "$PICKER" 2>&1
}

# ── Test 1: shipped-on-main gap (INFRA-9001) → skip ──────────────────────
echo "Test 1: INFRA-9001 (status:done on main) → picker skips, returns INFRA-9002"
out=$(cd "$TMP/work" && run_picker)
if [[ "$out" != "INFRA-9002" ]]; then
    echo "[FAIL] expected INFRA-9002, got: $out"
    exit 1
fi
echo "[PASS]"

# ── Test 2: only INFRA-9001 in candidates → picker should return nothing ─
# (since the only candidate is shipped on main; nothing left to pick)
echo ""
echo "Test 2: only shipped gap in candidates → picker returns nothing"
cat > "$TMP/gaps.json" <<'JSON'
[
  {"id":"INFRA-9001","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1000,"depends_on":""}
]
JSON
out=$(cd "$TMP/work" && run_picker)
if [[ -n "$out" ]]; then
    echo "[FAIL] expected empty output (all candidates filtered), got: $out"
    exit 1
fi
echo "[PASS]"

# ── Test 3: gap not on origin/main yet → picker picks it (no false skip) ─
echo ""
echo "Test 3: INFRA-9003 (no YAML on main) → picker picks it normally"
cat > "$TMP/gaps.json" <<'JSON'
[
  {"id":"INFRA-9003","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1002,"depends_on":""}
]
JSON
out=$(cd "$TMP/work" && run_picker)
if [[ "$out" != "INFRA-9003" ]]; then
    echo "[FAIL] expected INFRA-9003 (not on main → don't skip), got: $out"
    exit 1
fi
echo "[PASS]"

# ── Test 4: FLEET_SKIP_SHIPPED_CHECK=0 bypass — picker doesn't check ────
echo ""
echo "Test 4: FLEET_SKIP_SHIPPED_CHECK=0 → picker skips check, picks INFRA-9001"
cat > "$TMP/gaps.json" <<'JSON'
[
  {"id":"INFRA-9001","domain":"INFRA","priority":"P1","effort":"xs","status":"open","created_at":1000,"depends_on":""}
]
JSON
out=$(cd "$TMP/work" && run_picker FLEET_SKIP_SHIPPED_CHECK=0)
if [[ "$out" != "INFRA-9001" ]]; then
    echo "[FAIL] expected INFRA-9001 (bypass disables check), got: $out"
    exit 1
fi
echo "[PASS]"

echo ""
echo "[OK] all 4 FLEET-040 shipped-on-main skip cases passed"
