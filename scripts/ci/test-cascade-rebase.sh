#!/usr/bin/env bash
# scripts/ci/test-cascade-rebase.sh — INFRA-1458
#
# Smoke test for `chump pr cascade-rebase <check-name>`.
# Uses CHUMP_GH to inject a stub `gh` that simulates 3 PRs:
#   PR #101 — failing "foo-check"
#   PR #102 — failing "foo-check", labeled do-not-paramedic
#   PR #103 — failing "foo-check"
#   PR #104 — passing "foo-check" (should be excluded)
#
# Rounds:
#   1. Syntax + INFRA-1458 marker
#   2. Binary present + usage exits 2 on missing check-name
#   3. --dry-run: all 3 (non-excluded) PRs listed; gh update-branch NOT called
#   4. Real run: stub gh called for PRs 101 + 103 (not 102, excluded by label)
#   5. --json output: valid JSON with correct counts
#   6. kind=cascade_rebase_run emitted to ambient.jsonl
#   7. --skip-conflict: stub returns conflict on 101, continues to 103

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
info() { printf '\033[0;36m→\033[0m  %s\n' "$*"; }

[[ -f "$CHUMP_BIN" ]] || fail "chump binary missing: $CHUMP_BIN (build first)"

# ── 1. Marker check ──────────────────────────────────────────────────────────
grep -q "INFRA-1458" "$REPO_ROOT/src/cascade_rebase.rs" \
  || fail "INFRA-1458 marker missing from src/cascade_rebase.rs"
ok "INFRA-1458 marker present"

# ── Isolated test environment ─────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
AMBIENT="$WORK/ambient.jsonl"
mkdir -p "$WORK/.chump-locks"

# ── Stub gh binary ────────────────────────────────────────────────────────────
cat > "$WORK/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Stub gh for cascade-rebase testing
CALLS_LOG="${GH_CALLS_LOG:-/tmp/gh-calls.log}"

if [[ "$*" == *"pr list"* ]]; then
  # Return 4 PRs: 3 failing foo-check, 1 not; 102 has do-not-paramedic label
  cat <<'JSON'
[
  {"number":101,"title":"PR 101","headRefName":"branch-101","labels":[],"statusCheckRollup":[{"name":"foo-check","conclusion":"FAILURE"}]},
  {"number":102,"title":"PR 102","headRefName":"branch-102","labels":[{"name":"do-not-paramedic"}],"statusCheckRollup":[{"name":"foo-check","conclusion":"FAILURE"}]},
  {"number":103,"title":"PR 103","headRefName":"branch-103","labels":[],"statusCheckRollup":[{"name":"foo-check","conclusion":"FAILURE"}]},
  {"number":104,"title":"PR 104","headRefName":"branch-104","labels":[],"statusCheckRollup":[{"name":"foo-check","conclusion":"SUCCESS"}]}
]
JSON
  exit 0
fi

if [[ "$*" == *"pr update-branch"* ]]; then
  echo "update-branch:$*" >> "${CALLS_LOG}"
  # Simulate conflict on PR 101 if STUB_CONFLICT=1
  if [[ "${STUB_CONFLICT:-0}" == "1" ]] && [[ "$*" == *"101"* ]]; then
    echo "error: merge conflict" >&2
    exit 1
  fi
  echo "Branch updated"
  exit 0
fi

echo "stub: unhandled gh command: $*" >&2
exit 1
GHSTUB
chmod +x "$WORK/gh"

GH_CALLS_LOG="$WORK/gh-calls.log"

# Helper to run chump with stub gh
run_cascade() {
  CHUMP_GH="$WORK/gh" \
  GH_CALLS_LOG="$GH_CALLS_LOG" \
  CHUMP_AMBIENT_LOG="$AMBIENT" \
  CHUMP_REPO_ROOT="$WORK" \
    "$CHUMP_BIN" pr cascade-rebase "$@"
}

# ── 2. Usage error on missing check-name ─────────────────────────────────────
set +e
CHUMP_GH="$WORK/gh" "$CHUMP_BIN" pr cascade-rebase 2>/dev/null
EXIT2=$?
set -e
[[ "$EXIT2" -eq 2 ]] \
  || fail "round 2: expected exit 2 on missing check-name, got $EXIT2"
ok "round 2: exits 2 when check-name missing"

# ── 3. --dry-run: all matching PRs listed, no update-branch calls ─────────────
rm -f "$GH_CALLS_LOG"
OUTPUT3="$(run_cascade foo-check --dry-run 2>&1)"
# Should list PRs 101, 103 (102 excluded by label, 104 doesn't fail foo-check)
echo "$OUTPUT3" | grep -q "101" \
  || fail "round 3: PR 101 not in dry-run output (got: $OUTPUT3)"
echo "$OUTPUT3" | grep -q "103" \
  || fail "round 3: PR 103 not in dry-run output (got: $OUTPUT3)"
# 102 should show as skipped (excluded label)
echo "$OUTPUT3" | grep -q "102" \
  || fail "round 3: PR 102 (excluded) not shown in dry-run output"
echo "$OUTPUT3" | grep -qv "update-branch" || true   # no real update
[[ ! -f "$GH_CALLS_LOG" ]] || [[ ! -s "$GH_CALLS_LOG" ]] \
  || fail "round 3: gh update-branch was called in dry-run mode (calls: $(cat "$GH_CALLS_LOG"))"
ok "round 3: dry-run lists PRs, no update-branch calls"

# ── 4. Real run: PRs 101+103 updated, 102 skipped ─────────────────────────────
rm -f "$GH_CALLS_LOG" "$AMBIENT"
mkdir -p "$(dirname "$AMBIENT")"
OUTPUT4="$(run_cascade foo-check 2>&1)"
[[ -f "$GH_CALLS_LOG" ]] \
  || fail "round 4: gh update-branch never called"
grep -q "101" "$GH_CALLS_LOG" \
  || fail "round 4: PR 101 not rebased"
grep -q "103" "$GH_CALLS_LOG" \
  || fail "round 4: PR 103 not rebased"
grep -q "102" "$GH_CALLS_LOG" \
  && fail "round 4: PR 102 (labeled do-not-paramedic) was rebased — should be skipped" || true
ok "round 4: PRs 101+103 rebased, 102 skipped (excluded label)"

# ── 5. --json output ─────────────────────────────────────────────────────────
rm -f "$GH_CALLS_LOG" "$AMBIENT"
mkdir -p "$(dirname "$AMBIENT")"
JSON5="$(run_cascade foo-check --dry-run --json 2>/dev/null)"
python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert 'check_name' in d, 'missing check_name'
assert 'pr_count' in d, 'missing pr_count'
assert 'prs' in d and isinstance(d['prs'], list), 'prs not array'
assert d['dry_run'] == True, 'dry_run not true'
print('JSON valid, pr_count=' + str(d['pr_count']))
" "$JSON5" \
  || fail "round 5: --json output invalid or missing keys (got: $JSON5)"
ok "round 5: --json produces valid JSON with check_name, pr_count, prs[]"

# ── 6. Ambient event emitted ─────────────────────────────────────────────────
rm -f "$GH_CALLS_LOG" "$AMBIENT"
mkdir -p "$WORK/.chump-locks"
AMBIENT="$WORK/.chump-locks/ambient.jsonl"
CHUMP_GH="$WORK/gh" \
GH_CALLS_LOG="$GH_CALLS_LOG" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
CHUMP_REPO_ROOT="$WORK" \
  "$CHUMP_BIN" pr cascade-rebase foo-check 2>&1 || true
[[ -f "$AMBIENT" ]] && grep -q '"kind":"cascade_rebase_run"' "$AMBIENT" \
  || fail "round 6: cascade_rebase_run not in ambient.jsonl"
grep -q '"check"' "$AMBIENT" \
  || fail "round 6: 'check' field missing from cascade_rebase_run event"
ok "round 6: cascade_rebase_run emitted to ambient.jsonl"

# ── 7. --skip-conflict: conflict on 101, continues to 103 ────────────────────
rm -f "$GH_CALLS_LOG"
STUB_CONFLICT=1 CHUMP_GH="$WORK/gh" \
GH_CALLS_LOG="$GH_CALLS_LOG" \
CHUMP_AMBIENT_LOG="$AMBIENT" \
CHUMP_REPO_ROOT="$WORK" \
  "$CHUMP_BIN" pr cascade-rebase foo-check --skip-conflict 2>&1 || true
grep -q "101" "$GH_CALLS_LOG" 2>/dev/null \
  || fail "round 7: PR 101 update-branch not attempted"
grep -q "103" "$GH_CALLS_LOG" 2>/dev/null \
  || fail "round 7: PR 103 not processed after 101 conflict (--skip-conflict should continue)"
ok "round 7: --skip-conflict continues past conflict on PR 101 to PR 103"

echo ""
echo "All 7 checks PASSED — INFRA-1458 chump pr cascade-rebase verified"
