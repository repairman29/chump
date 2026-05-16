#!/usr/bin/env bash
# CI test: INFRA-1450 — orphan-branch-sweeper.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SWEEPER="$REPO_ROOT/scripts/coord/orphan-branch-sweeper.sh"
PASS=0; FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1450 orphan-branch-sweeper test ==="
echo

# ── 1. Structural checks ─────────────────────────────────────────────────────
[[ -x "$SWEEPER" ]] && ok "sweeper script is executable" || fail "sweeper not executable"

grep -q 'CHUMP_ORPHAN_BRANCH_AGE_DAYS' "$SWEEPER" \
    && ok "configurable age threshold via env" || fail "missing CHUMP_ORPHAN_BRANCH_AGE_DAYS"

grep -q 'CHUMP_ORPHAN_BRANCH_PROTECT_REGEX' "$SWEEPER" \
    && ok "custom protect regex env var present" || fail "missing CHUMP_ORPHAN_BRANCH_PROTECT_REGEX"

grep -qE '\-X DELETE' "$SWEEPER" \
    && ok "DELETE call present" || fail "missing -X DELETE"

grep -q 'orphan_branch_deleted' "$SWEEPER" \
    && ok "kind=orphan_branch_deleted ambient event" || fail "missing orphan_branch_deleted"

grep -q 'orphan_branch_sweep_run' "$SWEEPER" \
    && ok "kind=orphan_branch_sweep_run summary event" || fail "missing orphan_branch_sweep_run"

grep -q '\-\-dry-run' "$SWEEPER" && grep -q '\-\-apply' "$SWEEPER" \
    && ok "dry-run (default) and --apply flags" || fail "missing --dry-run or --apply flags"

grep -q 'DRY_RUN=1' "$SWEEPER" \
    && ok "dry-run is default" || fail "dry-run should be default"

# ── 2. Stub: stale branch with no open PR → candidate ───────────────────────
echo
echo "--- Stub: stale branch, no open PR → flagged as candidate ---"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AMB="$TMPDIR_TEST/ambient.jsonl"; touch "$AMB"
GH_LOG="$TMPDIR_TEST/gh.log"; touch "$GH_LOG"

OLD_DATE="2025-01-01T00:00:00Z"

cat > "$TMPDIR_TEST/gh" <<GHSTUB
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$*" in
  *"branches?per_page=100&page=1"*)
    printf "chump/stale-branch-xyz\nmain\n"
    ;;
  *"pulls?state=open"*)
    echo ""
    ;;
  *"branches/chump/stale-branch-xyz"*)
    # Return just the --jq-extracted value (date string).
    echo "$OLD_DATE"
    ;;
  *"branches/main"*)
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ;;
esac
GHSTUB
chmod +x "$TMPDIR_TEST/gh"

# Run in dry-run mode with 14d threshold and stub gh.
OUTPUT=$(CHUMP_AMBIENT_LOG="$AMB" CHUMP_ORPHAN_BRANCH_AGE_DAYS=14 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$SWEEPER" --dry-run 2>&1 || true)

if echo "$OUTPUT" | grep -q "CANDIDATE.*stale-branch-xyz"; then
    ok "stub: stale orphan branch flagged as CANDIDATE"
else
    fail "stub: stale orphan branch not flagged (output: $(echo "$OUTPUT" | tail -3))"
fi

if ! echo "$OUTPUT" | grep -q "CANDIDATE.*main"; then
    ok "stub: main branch not flagged"
else
    fail "stub: main branch incorrectly flagged as candidate"
fi

# Dry-run: no DELETE call and no ambient event.
if ! grep -q "\-X DELETE" "$GH_LOG" 2>/dev/null; then
    ok "stub dry-run: no DELETE call issued"
else
    fail "stub dry-run: DELETE call should not fire in dry-run mode"
fi

if ! grep -q "orphan_branch_deleted" "$AMB" 2>/dev/null; then
    ok "stub dry-run: no orphan_branch_deleted event emitted"
else
    fail "stub dry-run: orphan_branch_deleted event should not fire in dry-run"
fi

# ── 3. Stub: open PR on branch → skipped ────────────────────────────────────
echo
echo "--- Stub: branch has open PR → skipped ---"

GH_LOG2="$TMPDIR_TEST/gh2.log"; touch "$GH_LOG2"
AMB2="$TMPDIR_TEST/ambient2.jsonl"; touch "$AMB2"

cat > "$TMPDIR_TEST/gh" <<GHSTUB2
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG2"
case "\$*" in
  *"branches?per_page=100&page=1"*)
    printf "chump/active-branch\nmain\n"
    ;;
  *"pulls?state=open"*)
    echo "chump/active-branch"
    ;;
  *"branches/chump/active-branch"*)
    echo '{"commit":{"commit":{"committer":{"date":"2025-01-01T00:00:00Z"}}}}'
    ;;
esac
GHSTUB2
chmod +x "$TMPDIR_TEST/gh"

OUTPUT2=$(CHUMP_AMBIENT_LOG="$AMB2" CHUMP_ORPHAN_BRANCH_AGE_DAYS=14 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$SWEEPER" --dry-run 2>&1 || true)

if ! echo "$OUTPUT2" | grep -q "CANDIDATE.*active-branch"; then
    ok "stub: branch with open PR not flagged as candidate"
else
    fail "stub: branch with open PR incorrectly flagged (skipped_open_pr should catch it)"
fi

# ── 4. Stub: recent commit → skipped ─────────────────────────────────────────
echo
echo "--- Stub: recent commit → below age threshold ---"

GH_LOG3="$TMPDIR_TEST/gh3.log"; touch "$GH_LOG3"
AMB3="$TMPDIR_TEST/ambient3.jsonl"; touch "$AMB3"
RECENT_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$TMPDIR_TEST/gh" <<GHSTUB3
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG3"
case "\$*" in
  *"branches?per_page=100&page=1"*)
    printf "chump/recent-branch\n"
    ;;
  *"pulls?state=open"*) echo "" ;;
  *"branches/chump/recent-branch"*)
    # Return pre-jq-extracted date string directly.
    echo "$RECENT_DATE"
    ;;
esac
GHSTUB3
chmod +x "$TMPDIR_TEST/gh"

OUTPUT3=$(CHUMP_AMBIENT_LOG="$AMB3" CHUMP_ORPHAN_BRANCH_AGE_DAYS=14 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$SWEEPER" --dry-run 2>&1 || true)

if ! echo "$OUTPUT3" | grep -q "CANDIDATE"; then
    ok "stub: recent branch below threshold not flagged"
else
    fail "stub: recent branch incorrectly flagged as candidate"
fi

# ── 5. Event registry check ──────────────────────────────────────────────────
echo
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
if grep -q "orphan_branch_deleted" "$REGISTRY" && grep -q "orphan_branch_sweep_run" "$REGISTRY"; then
    ok "both ambient kinds registered in EVENT_REGISTRY.yaml"
else
    fail "one or more kinds missing from EVENT_REGISTRY.yaml"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
