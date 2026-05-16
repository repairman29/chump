#!/usr/bin/env bash
# CI test: INFRA-1453 — branch-reaper.sh emits kind=branch_reaped + kind=branch_reaper_run_summary
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
REAPER="$REPO_ROOT/scripts/coord/branch-reaper.sh"
PASS=0; FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1453 branch-reaper ambient emit test ==="
echo

# ── 1. Structural checks ─────────────────────────────────────────────────────
grep -q 'branch_reaped' "$REAPER" \
    && ok "reaper emits kind=branch_reaped" || fail "branch_reaped missing from reaper"

grep -q 'branch_reaper_run_summary' "$REAPER" \
    && ok "reaper emits kind=branch_reaper_run_summary" || fail "branch_reaper_run_summary missing"

grep -q '\-\-emit-anyway' "$REAPER" \
    && ok "--emit-anyway flag present" || fail "--emit-anyway flag missing"

grep -q 'reaper_run_id\|REAPER_RUN_ID' "$REAPER" \
    && ok "reaper_run_id field present" || fail "reaper_run_id missing"

grep -q 'branch_name' "$REAPER" \
    && ok "branch_name field (not just branch) in branch_reaped" || fail "branch_name field missing"

# ── 2. Registry checks ────────────────────────────────────────────────────────
echo
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

grep -q 'kind: branch_reaped' "$REGISTRY" \
    && ok "branch_reaped registered in EVENT_REGISTRY" || fail "branch_reaped not in EVENT_REGISTRY"

grep -q 'kind: branch_reaper_run_summary' "$REGISTRY" \
    && ok "branch_reaper_run_summary registered in EVENT_REGISTRY" || fail "branch_reaper_run_summary not in EVENT_REGISTRY"

# ── 3. Stub functional test: --dry-run --emit-anyway emits branch_reaped ─────
echo
echo "--- Stub: dry-run --emit-anyway → branch_reaped + summary emitted ---"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMB="$TMPDIR_TEST/ambient.jsonl"; touch "$AMB"
GH_LOG="$TMPDIR_TEST/gh.log"; touch "$GH_LOG"
OLD_DATE="2025-01-01T00:00:00Z"

# Stub gh: returns one stale closed PR branch + main.
cat > "$TMPDIR_TEST/gh" <<GHSTUB
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$*" in
  *"branches?per_page=100&page=1"*)
    printf "chump/stale-infra-999-claim\nmain\n"
    ;;
  *"branches?per_page=100&page="*)
    echo ""
    ;;
  *"pulls?state=closed"*"stale-infra-999"*)
    printf '{"merged_at":"2025-01-02T00:00:00Z","closed_at":"2025-01-02T00:00:00Z","number":999}\n'
    ;;
  *"git/refs/heads"*)
    exit 0
    ;;
esac
GHSTUB
chmod +x "$TMPDIR_TEST/gh"

OUTPUT=$(CHUMP_AMBIENT_LOG="$AMB" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$REAPER" --dry-run --emit-anyway 2>&1 || true)

if grep -q '"kind":"branch_reaped"' "$AMB" 2>/dev/null; then
    ok "stub: kind=branch_reaped emitted in dry-run --emit-anyway"
else
    fail "stub: kind=branch_reaped not emitted (output: $(echo "$OUTPUT" | tail -3))"
fi

if grep -q '"kind":"branch_reaper_run_summary"' "$AMB" 2>/dev/null; then
    ok "stub: kind=branch_reaper_run_summary emitted"
else
    fail "stub: kind=branch_reaper_run_summary not emitted"
fi

# Verify branch_reaped has required fields.
REAPED_LINE=$(grep '"kind":"branch_reaped"' "$AMB" | head -1)
for field in branch_name age_days repo reaper_run_id; do
    if echo "$REAPED_LINE" | grep -q "\"$field\""; then
        ok "branch_reaped has field: $field"
    else
        fail "branch_reaped missing field: $field"
    fi
done

# ── 4. Stub: plain --dry-run (no --emit-anyway) → branch_reaped NOT emitted ──
echo
echo "--- Stub: plain dry-run → branch_reaped suppressed ---"

AMB2="$TMPDIR_TEST/ambient2.jsonl"; touch "$AMB2"

CHUMP_AMBIENT_LOG="$AMB2" PATH="$TMPDIR_TEST:$PATH" \
    bash "$REAPER" --dry-run 2>&1 >/dev/null || true

if ! grep -q '"kind":"branch_reaped"' "$AMB2" 2>/dev/null; then
    ok "stub: branch_reaped NOT emitted in plain dry-run (no --emit-anyway)"
else
    fail "stub: branch_reaped should be suppressed in plain dry-run"
fi

# branch_reaper_run_summary IS always emitted.
if grep -q '"kind":"branch_reaper_run_summary"' "$AMB2" 2>/dev/null; then
    ok "stub: branch_reaper_run_summary emitted even in plain dry-run"
else
    fail "stub: branch_reaper_run_summary should always emit"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
