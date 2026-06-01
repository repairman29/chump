#!/usr/bin/env bash
# scripts/ci/test-pr-queue-processor.sh — INFRA-2346 integration test
#
# Asserts the pr-queue auto-processor tiers in pr-shepherd-daemon.sh:
#   1. trusted+green PR → admin_merge action fires
#   2. trusted+behind PR → no admin_merge action (deferred to existing rebase logic)
#   3. untrusted+green PR → no admin_merge action (logged-not-merged via classification only)
#   4. trunk_red ambient event present → ALL admin_merges skipped with reason=trunk_red
#   5. known-flake PR → flake_rerun action fires
#   6. flake-rerun cap exceeded → flake_rerun_skipped reason=capped
#
# Runs under bash 3.2 (macOS default). No external services — we stub gh
# via PATH and feed synthetic ambient.jsonl.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh"

[[ -x "$DAEMON" ]] || { echo "[test] FAIL: daemon not executable"; exit 1; }

# Isolated work dir for each scenario
WORK_DIR="$(mktemp -d /tmp/pr-queue-processor-test-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── stub gh ───────────────────────────────────────────────────────────────────
# We install a fake `gh` in $WORK_DIR/bin and prepend to PATH.
# It reads a $GH_FIXTURE env var that points at a JSON file containing the
# response for `gh pr list ...`. For `gh pr merge` / `gh run rerun` / `gh run list`
# it logs the invocation to $GH_CALL_LOG and returns success (or controlled exit).

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/gh" << 'GHEOF'
#!/usr/bin/env bash
# Stub gh for the pr-queue-processor test.
# - `gh pr list ... --json ...`  → echo $GH_FIXTURE contents
# - `gh pr merge ...`            → log invocation; exit ${GH_MERGE_EXIT:-0}
# - `gh run rerun ...`           → log invocation; exit ${GH_RERUN_EXIT:-0}
# - `gh run list ... --jq ...`   → echo ${GH_RUN_ID:-12345}
# - `gh api ...`                 → exit 0 silently (cache lib fallback)
LOG="${GH_CALL_LOG:-/dev/null}"
echo "gh $*" >> "$LOG"
case "${1:-}" in
  pr)
    case "${2:-}" in
      list)
        cat "${GH_FIXTURE:-/dev/null}"
        exit 0
        ;;
      merge)
        exit "${GH_MERGE_EXIT:-0}"
        ;;
      view)
        # cache-lib fallback PR view — return minimal JSON
        echo '{}'
        exit 0
        ;;
    esac
    ;;
  run)
    case "${2:-}" in
      rerun)
        exit "${GH_RERUN_EXIT:-0}"
        ;;
      list)
        echo "${GH_RUN_ID:-12345}"
        exit 0
        ;;
    esac
    ;;
  api)
    # cache lib calls — return empty JSON object, exit 0
    echo '{}'
    exit 0
    ;;
esac
# Default: success
exit 0
GHEOF
chmod +x "$WORK_DIR/bin/gh"

# Per-scenario isolation helper
run_scenario() {
  local name="$1" fixture="$2" trunk_red="${3:-0}" merge_exit="${5:-0}"
  local flake_count_init="${4:-}"
  [[ -z "$flake_count_init" ]] && flake_count_init='{}'
  local SC_DIR="$WORK_DIR/$name"
  mkdir -p "$SC_DIR/.chump-locks" "$SC_DIR/.chump" "$SC_DIR/docs/process"

  # Synthetic KNOWN_FLAKES.yaml with one check_flakes entry.
  cat > "$SC_DIR/docs/process/KNOWN_FLAKES.yaml" << 'KNOWNEOF'
schema_version: 1
last_audit: "2026-05-31"
flakes: []
check_flakes:
  - check_name: "ci.yml / fast-checks"
    reason: "test fixture entry — INFRA-2346 integration test"
    tracking_gap: INFRA-2346
    added: "2026-05-31"
    last_observed: "2026-05-31"
    max_reruns: 2
KNOWNEOF

  # Pre-seed flake-rerun counter file if specified
  echo "$flake_count_init" > "$SC_DIR/.chump-locks/flake-rerun-count.json"

  # If trunk_red flag set, prime ambient with a recent trunk_state_change event.
  if [ "$trunk_red" = "1" ]; then
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"trunk_state_change","state":"TRUNK_RED"}\n' "$ts" \
      > "$SC_DIR/.chump-locks/ambient.jsonl"
  else
    : > "$SC_DIR/.chump-locks/ambient.jsonl"
  fi

  local CALL_LOG="$SC_DIR/.chump-locks/gh-calls.log"
  : > "$CALL_LOG"

  # Run one tick with stubbed gh + isolated ambient + isolated state files.
  # CHUMP_PR_SHEPHERD_DRY_RUN=1 is intentionally UNSET so admin_merge actually
  # invokes the gh stub (we assert the invocation). The stub returns success
  # for `gh pr merge` so no real merge happens; the meta-186 file-followup-gap
  # path can call `chump gap reserve` for real BUT this test only feeds
  # synthetic PR numbers (1001-1007) — gap reserve writes new gaps unrelated to
  # any existing fixture-protected gap ID. To fully isolate the test in CI
  # we set CHUMP_GAP_RESERVE_NO_SIMILARITY=1 + CHUMP_FAKE_GAP_RESERVE=1
  # (the daemon will see a non-zero exit and skip persistence).
  # Belt-and-suspenders: also expose a stub `chump` shim that just exits 0
  # for `chump gap reserve` so the daemon doesn't mutate the real registry.
  cat > "$WORK_DIR/bin/chump" << 'CHEOF' 2>/dev/null
#!/usr/bin/env bash
# stub chump for the pr-queue-processor test — only handles `chump gap reserve`
case "${1:-} ${2:-}" in
  "gap reserve")
    # Return a synthetic gap ID like the real chump does.
    echo "Reserved gap INFRA-9999"
    exit 0
    ;;
esac
exit 0
CHEOF
  chmod +x "$WORK_DIR/bin/chump"

  PATH="$WORK_DIR/bin:$PATH" \
    GH_FIXTURE="$fixture" \
    GH_CALL_LOG="$CALL_LOG" \
    GH_MERGE_EXIT="$merge_exit" \
    CHUMP_AMBIENT_PATH="$SC_DIR/.chump-locks/ambient.jsonl" \
    CHUMP_KNOWN_FLAKES_FILE="$SC_DIR/docs/process/KNOWN_FLAKES.yaml" \
    CHUMP_FLAKE_RERUN_FILE="$SC_DIR/.chump-locks/flake-rerun-count.json" \
    CHUMP_WEDGED_SIGNAL_FILE="$SC_DIR/.chump-locks/pr-wedged-signaled.json" \
    CHUMP_PR_SHEPHERD_MAX_ADMIN_MERGES_PER_TICK=3 \
    CHUMP_PR_SHEPHERD_MAX_FLAKE_RERUNS_PER_PR=2 \
    TRUST_AUTHORS="fleet-bot,dependabot[bot],claude-bot,repairman29" \
    "$DAEMON" tick 2>/dev/null || true

  # Output the resulting ambient lines + gh log paths so the caller can assert.
  echo "AMBIENT:$SC_DIR/.chump-locks/ambient.jsonl"
  echo "GH_LOG:$CALL_LOG"
}

count_events() {
  local file="$1" kind="$2" action_filter="${3:-}"
  local c
  if [ -n "$action_filter" ]; then
    c=$(grep -c "\"kind\":\"$kind\".*\"action\":\"$action_filter\"" "$file" 2>/dev/null) || c=0
  else
    c=$(grep -c "\"kind\":\"$kind\"" "$file" 2>/dev/null) || c=0
  fi
  # Ensure single integer, no newlines
  printf '%d' "$c"
}

# ── Scenario 1: trusted+green → admin_merge fires ────────────────────────────
FIX1="$WORK_DIR/fix1.json"
cat > "$FIX1" << 'PREOF'
[
  {
    "number": 1001,
    "title": "INFRA-1234 fix",
    "mergeStateStatus": "CLEAN",
    "autoMergeRequest": null,
    "createdAt": "2026-05-31T10:00:00Z",
    "updatedAt": "2026-05-31T10:30:00Z",
    "headRefOid": "abc123",
    "headRefName": "feature-1234",
    "baseRefName": "main",
    "author": {"login": "fleet-bot"},
    "statusCheckRollup": []
  }
]
PREOF

result1=$(run_scenario s1 "$FIX1" 0)
ambient1=$(echo "$result1" | grep AMBIENT | cut -d: -f2)
log1=$(echo "$result1" | grep GH_LOG | cut -d: -f2)
admin_merges_s1=$(count_events "$ambient1" "pr_queue_auto_action" "admin_merge")
if [ "$admin_merges_s1" -lt 1 ]; then
  echo "[test] FAIL scenario 1: trusted+green PR did not get admin_merge action"
  echo "--- ambient ---"; cat "$ambient1"
  echo "--- gh-log ---"; cat "$log1"
  exit 1
fi
# Verify gh pr merge --squash --admin was invoked
if ! grep -q 'pr merge 1001 --squash --admin' "$log1"; then
  echo "[test] FAIL scenario 1: gh pr merge --admin not invoked"
  cat "$log1"
  exit 1
fi
echo "[test] scenario 1 (trusted+green → admin_merge): OK"

# ── Scenario 2: trusted+behind → no admin_merge (deferred to rebase) ─────────
FIX2="$WORK_DIR/fix2.json"
cat > "$FIX2" << 'PREOF'
[
  {
    "number": 1002,
    "title": "INFRA-1235 fix",
    "mergeStateStatus": "BEHIND",
    "autoMergeRequest": null,
    "createdAt": "2026-05-31T10:00:00Z",
    "updatedAt": "2026-05-31T10:30:00Z",
    "headRefOid": "def456",
    "headRefName": "feature-1235",
    "baseRefName": "main",
    "author": {"login": "fleet-bot"},
    "statusCheckRollup": []
  }
]
PREOF

result2=$(run_scenario s2 "$FIX2" 0)
ambient2=$(echo "$result2" | grep AMBIENT | cut -d: -f2)
log2=$(echo "$result2" | grep GH_LOG | cut -d: -f2)
admin_merges_s2=$(count_events "$ambient2" "pr_queue_auto_action" "admin_merge")
if [ "$admin_merges_s2" -gt 0 ]; then
  echo "[test] FAIL scenario 2: BEHIND PR should not admin_merge (got $admin_merges_s2)"
  cat "$ambient2"
  exit 1
fi
echo "[test] scenario 2 (trusted+behind → no admin_merge): OK"

# ── Scenario 3: untrusted+green → no admin_merge (just classified) ──────────
FIX3="$WORK_DIR/fix3.json"
cat > "$FIX3" << 'PREOF'
[
  {
    "number": 1003,
    "title": "user contribution",
    "mergeStateStatus": "CLEAN",
    "autoMergeRequest": null,
    "createdAt": "2026-05-31T10:00:00Z",
    "updatedAt": "2026-05-31T10:30:00Z",
    "headRefOid": "ghi789",
    "headRefName": "user-feature",
    "baseRefName": "main",
    "author": {"login": "external-contributor"},
    "statusCheckRollup": []
  }
]
PREOF

result3=$(run_scenario s3 "$FIX3" 0)
ambient3=$(echo "$result3" | grep AMBIENT | cut -d: -f2)
admin_merges_s3=$(count_events "$ambient3" "pr_queue_auto_action" "admin_merge")
if [ "$admin_merges_s3" -gt 0 ]; then
  echo "[test] FAIL scenario 3: untrusted PR was admin-merged (got $admin_merges_s3)"
  cat "$ambient3"
  exit 1
fi
# Should still be classified as MERGEABLE — verify the classification event exists
if ! grep -q '"kind":"pr_classified".*"pr":1003' "$ambient3"; then
  echo "[test] FAIL scenario 3: untrusted PR not classified"
  cat "$ambient3"
  exit 1
fi
echo "[test] scenario 3 (untrusted+green → no admin_merge, but classified): OK"

# ── Scenario 4: trunk_red event → ALL admin_merges skipped ──────────────────
FIX4="$WORK_DIR/fix4.json"
cat > "$FIX4" << 'PREOF'
[
  {
    "number": 1004,
    "title": "INFRA-1236 fix",
    "mergeStateStatus": "CLEAN",
    "autoMergeRequest": null,
    "createdAt": "2026-05-31T10:00:00Z",
    "updatedAt": "2026-05-31T10:30:00Z",
    "headRefOid": "jkl012",
    "headRefName": "feature-1236",
    "baseRefName": "main",
    "author": {"login": "fleet-bot"},
    "statusCheckRollup": []
  },
  {
    "number": 1005,
    "title": "INFRA-1237 fix",
    "mergeStateStatus": "CLEAN",
    "autoMergeRequest": null,
    "createdAt": "2026-05-31T10:00:00Z",
    "updatedAt": "2026-05-31T10:30:00Z",
    "headRefOid": "mno345",
    "headRefName": "feature-1237",
    "baseRefName": "main",
    "author": {"login": "claude-bot"},
    "statusCheckRollup": []
  }
]
PREOF

result4=$(run_scenario s4 "$FIX4" 1)
ambient4=$(echo "$result4" | grep AMBIENT | cut -d: -f2)
log4=$(echo "$result4" | grep GH_LOG | cut -d: -f2)
admin_merges_s4=$(count_events "$ambient4" "pr_queue_auto_action" "admin_merge")
admin_skipped_s4=$(count_events "$ambient4" "pr_queue_auto_action" "admin_merge_skipped")
trunk_red_skips=$(count_events "$ambient4" "pr_queue_skipped_trunk_red")

# Note: cascade_held also fires on TRUNK_RED state, which may produce skips
# with reason=trunk_red. Either gate firing is acceptable.
if [ "$admin_merges_s4" -gt 0 ]; then
  echo "[test] FAIL scenario 4: trunk_red did not block admin_merge (got $admin_merges_s4)"
  cat "$ambient4"
  exit 1
fi
if [ "$admin_skipped_s4" -lt 2 ]; then
  echo "[test] FAIL scenario 4: expected ≥2 admin_merge_skipped events, got $admin_skipped_s4"
  cat "$ambient4"
  exit 1
fi
if [ "$trunk_red_skips" -lt 1 ]; then
  echo "[test] FAIL scenario 4: pr_queue_skipped_trunk_red rollup not emitted"
  cat "$ambient4"
  exit 1
fi
# Verify gh pr merge was NOT invoked
if grep -q 'pr merge 1004 --squash --admin' "$log4" || grep -q 'pr merge 1005 --squash --admin' "$log4"; then
  echo "[test] FAIL scenario 4: gh pr merge was invoked despite trunk_red"
  cat "$log4"
  exit 1
fi
echo "[test] scenario 4 (trunk_red → all admin_merges blocked + rollup emitted): OK"

# ── Scenario 5: known-flake → flake_rerun fires ──────────────────────────────
FIX5="$WORK_DIR/fix5.json"
cat > "$FIX5" << 'PREOF'
[
  {
    "number": 1006,
    "title": "INFRA-1238 fix",
    "mergeStateStatus": "BLOCKED",
    "autoMergeRequest": null,
    "createdAt": "2026-05-31T10:00:00Z",
    "updatedAt": "2026-05-31T10:30:00Z",
    "headRefOid": "pqr678",
    "headRefName": "feature-1238",
    "baseRefName": "main",
    "author": {"login": "fleet-bot"},
    "statusCheckRollup": [
      {"name": "ci.yml / fast-checks", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": "https://example.com/run/1"}
    ]
  }
]
PREOF

result5=$(run_scenario s5 "$FIX5" 0)
ambient5=$(echo "$result5" | grep AMBIENT | cut -d: -f2)
log5=$(echo "$result5" | grep GH_LOG | cut -d: -f2)
# Note: scenario 5 PR is trusted+BLOCKED_REAL_FAIL+all-flake. CLEAN_GREEN tier
# DOES NOT fire (mergeStateStatus=BLOCKED with a FAILURE → BLOCKED_REAL_FAIL,
# is_clean_green=False). So flake_rerun tier should fire instead.
flake_reruns_s5=$(count_events "$ambient5" "pr_queue_auto_action" "flake_rerun")
if [ "$flake_reruns_s5" -lt 1 ]; then
  echo "[test] FAIL scenario 5: known-flake did not trigger flake_rerun"
  cat "$ambient5"
  exit 1
fi
# Verify gh run rerun was invoked
if ! grep -q 'run rerun' "$log5"; then
  echo "[test] FAIL scenario 5: gh run rerun not invoked"
  cat "$log5"
  exit 1
fi
echo "[test] scenario 5 (known-flake → flake_rerun fires): OK"

# ── Scenario 6: flake-rerun cap exceeded → no rerun ──────────────────────────
# Pre-seed flake-rerun count with PR 1007 already at 2 (the cap).
result6=$(run_scenario s6 "$FIX5" 0 '{"1006":2}')
ambient6=$(echo "$result6" | grep AMBIENT | cut -d: -f2)
log6=$(echo "$result6" | grep GH_LOG | cut -d: -f2)
flake_reruns_s6=$(count_events "$ambient6" "pr_queue_auto_action" "flake_rerun")
flake_skipped_s6=$(count_events "$ambient6" "pr_queue_auto_action" "flake_rerun_skipped")
# When cap is hit, no flake_rerun fires; a flake_rerun_skipped reason=capped emits.
if [ "$flake_reruns_s6" -gt 0 ]; then
  echo "[test] FAIL scenario 6: flake_rerun fired despite cap (got $flake_reruns_s6)"
  cat "$ambient6"
  exit 1
fi
if [ "$flake_skipped_s6" -lt 1 ]; then
  echo "[test] FAIL scenario 6: expected flake_rerun_skipped, got $flake_skipped_s6"
  cat "$ambient6"
  exit 1
fi
# Verify cap reason
if ! grep -q '"action":"flake_rerun_skipped".*"reason":"capped"' "$ambient6"; then
  echo "[test] FAIL scenario 6: missing reason=capped on skip"
  cat "$ambient6"
  exit 1
fi
echo "[test] scenario 6 (flake-rerun cap exceeded → blocked): OK"

echo "[test] PASS — all 6 pr-queue-processor scenarios green"
