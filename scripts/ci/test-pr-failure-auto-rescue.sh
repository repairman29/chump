#!/usr/bin/env bash
# test-pr-failure-auto-rescue.sh — INFRA-1600
#
# Smoke tests for the auto-rescue daemon. Source-shape only (no real gh
# calls). Verifies:
#   1. Script exists + executable
#   2. --dry-run + --help flags supported
#   3. All 5 known handlers present
#   4. Cool-down + max-per-PR safety logic present
#   5. Ambient event emission shape

set -uo pipefail
PASS=0
FAIL=0
FAILS=()

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/pr-failure-auto-rescue.sh"

echo "=== INFRA-1600 PR auto-rescue daemon smoke ==="

# Test 1: present + executable
if [[ -x "$DAEMON" ]]; then
    ok "daemon script present + executable"
else
    fail "daemon script missing or not executable: $DAEMON"
fi

# Test 2: --help works
if bash "$DAEMON" --help 2>&1 | grep -q "Usage:"; then
    ok "--help accepted"
else
    fail "--help did not produce usage"
fi

# Test 3: all 5 handlers present
HANDLERS="cargo_fmt_drift cargo_not_found chump_bin_not_found tauri_flake adjacent_string_eprintln"
missing_handlers=""
for h in $HANDLERS; do
    if ! grep -q "handle_$h" "$DAEMON"; then
        missing_handlers="$missing_handlers $h"
    fi
done
if [[ -z "$missing_handlers" ]]; then
    ok "all 5 known handlers present"
else
    fail "missing handlers:$missing_handlers"
fi

# Test 4: safety logic (cooldown + max-per-PR)
if grep -q "in_cooldown" "$DAEMON" && grep -q "count_past_rescues" "$DAEMON"; then
    ok "cool-down + max-per-PR safety logic present"
else
    fail "safety logic missing"
fi

# Test 5: ambient emit shape
if grep -q "pr_auto_rescue_invoked" "$DAEMON"; then
    ok "emits kind=pr_auto_rescue_invoked"
else
    fail "ambient emit kind missing"
fi

# Test 6: --dry-run does not actually push or commit
out=$(bash "$DAEMON" --dry-run 2>&1)
if echo "$out" | grep -q "scanning"; then
    ok "--dry-run scans without action"
else
    fail "--dry-run did not produce expected output"
fi

# Test 7: RESILIENT-296 freshness gate present in source
if grep -q "PR_TERMINAL_FRESHNESS_MIN" "$DAEMON" && grep -q "curator_skip_active_rebase" "$DAEMON"; then
    ok "RESILIENT-296 freshness gate present (PR_TERMINAL_FRESHNESS_MIN + curator_skip_active_rebase)"
else
    fail "RESILIENT-296 freshness gate missing"
fi

# Test 8 (functional, RESILIENT-296): a PR that is armed + BLOCKED + a
# required check RED past PR_TERMINAL_HOURS, but whose updatedAt is inside
# the freshness window (a fix was just pushed, CI re-running), must be
# DEFERRED, not closed. This reproduces the #3598 false-close class: without
# the freshness gate, try_terminal_dispose would print "TERMINAL (dry-run):
# ... WOULD close" for this input.
FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN"' EXIT

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh: for `pr view` return the JSON pointed to by GH_STUB_JSON_FILE.
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    cat "$GH_STUB_JSON_FILE"
    exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/gh"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
hours_ago_iso() {
    local h="$1"
    date -u -v-"${h}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "-${h} hours" +%Y-%m-%dT%H:%M:%SZ
}
minutes_ago_iso() {
    local m="$1"
    date -u -v-"${m}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "-${m} minutes" +%Y-%m-%dT%H:%M:%SZ
}

STUB_JSON="$FAKE_BIN/pr.json"
cat > "$STUB_JSON" <<EOF
{
  "autoMergeRequest": {"enabledAt": "$(hours_ago_iso 8)"},
  "mergeStateStatus": "BLOCKED",
  "createdAt": "$(hours_ago_iso 8)",
  "updatedAt": "$(minutes_ago_iso 2)",
  "headRefName": "chump/resilient-296-claim",
  "statusCheckRollup": [
    {"name": "audit", "conclusion": "FAILURE"}
  ]
}
EOF

out=$(PATH="$FAKE_BIN:$PATH" GH_STUB_JSON_FILE="$STUB_JSON" \
    PR_TERMINAL_HOURS=6 PR_TERMINAL_FRESHNESS_MIN=10 \
    CHECK_PR=3598 bash "$DAEMON" 2>&1)

if echo "$out" | grep -q "SKIP CLOSE (RESILIENT-296)"; then
    ok "freshness gate defers close for recently-updated red-armed PR (#3598 class)"
else
    fail "freshness gate did not defer close for recently-updated PR: $out"
fi
if echo "$out" | grep -q "WOULD close"; then
    fail "freshness gate did not prevent WOULD-close diagnostic for fresh PR"
else
    ok "no WOULD-close diagnostic emitted for fresh PR"
fi

# Test 9 (control): same PR but updatedAt is ALSO stale (past freshness
# window) — this must still dispose, proving the gate doesn't just always skip.
STUB_JSON_STALE="$FAKE_BIN/pr-stale.json"
cat > "$STUB_JSON_STALE" <<EOF
{
  "autoMergeRequest": {"enabledAt": "$(hours_ago_iso 8)"},
  "mergeStateStatus": "BLOCKED",
  "createdAt": "$(hours_ago_iso 8)",
  "updatedAt": "$(hours_ago_iso 7)",
  "headRefName": "chump/resilient-296-claim",
  "statusCheckRollup": [
    {"name": "audit", "conclusion": "FAILURE"}
  ]
}
EOF

# RESILIENT-379: the dispose path is now opt-in (PR_TERMINAL_CLOSE_ARMED=1); the
# default is alert-not-reap (test 11 below). Run this control in legacy mode so it
# still proves the freshness gate isn't always-skip when close IS enabled.
out_stale=$(PATH="$FAKE_BIN:$PATH" GH_STUB_JSON_FILE="$STUB_JSON_STALE" \
    PR_TERMINAL_HOURS=6 PR_TERMINAL_FRESHNESS_MIN=10 PR_TERMINAL_CLOSE_ARMED=1 \
    CHECK_PR=3598 bash "$DAEMON" 2>&1)

if echo "$out_stale" | grep -q "WOULD close"; then
    ok "stale-updated red-armed PR still disposes under PR_TERMINAL_CLOSE_ARMED=1 (gate is not always-skip)"
else
    fail "stale-updated red-armed PR unexpectedly deferred in legacy close mode: $out_stale"
fi

# Test 10 (functional, RESILIENT-299): a PR that is armed + BLOCKED + a
# required check RED past PR_TERMINAL_HOURS, whose updatedAt is ALSO stale
# (so it would otherwise dispose per test 9), must be LEFT OPEN when >=2
# other open PRs share the same failing check — a systemic gate outage, not
# a per-PR failure (the #3633/#3623/#3598 reap class this gap fixes).
FAKE_BIN2="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN2"' EXIT

STUB_LIST="$FAKE_BIN2/list.json"
cat > "$STUB_LIST" <<'EOF'
[
  {"number": 4001, "statusCheckRollup": [{"name": "audit", "conclusion": "FAILURE"}]},
  {"number": 4002, "statusCheckRollup": [{"name": "audit", "conclusion": "FAILURE"}]},
  {"number": 3598, "statusCheckRollup": [{"name": "audit", "conclusion": "FAILURE"}]}
]
EOF

cat > "$FAKE_BIN2/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
    cat "\$GH_STUB_JSON_FILE"
    exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
    cat "$STUB_LIST"
    exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN2/gh"

out_systemic=$(PATH="$FAKE_BIN2:$PATH" GH_STUB_JSON_FILE="$STUB_JSON_STALE" \
    PR_TERMINAL_HOURS=6 PR_TERMINAL_FRESHNESS_MIN=10 \
    CHECK_PR=3598 bash "$DAEMON" 2>&1)

if echo "$out_systemic" | grep -q "SKIP CLOSE (RESILIENT-299)"; then
    ok "systemic shared-red PR (N>=2) is left open, not reaped"
else
    fail "systemic shared-red PR was not deferred: $out_systemic"
fi
if echo "$out_systemic" | grep -q "WOULD close"; then
    fail "systemic shared-red PR unexpectedly produced a WOULD-close diagnostic"
else
    ok "no WOULD-close diagnostic for systemic shared-red PR"
fi

# Test 11 (functional, RESILIENT-379 — THE incident regression): an armed + BLOCKED
# + required-check RED past PR_TERMINAL_HOURS, whose updatedAt is ALSO stale (so it
# would dispose under legacy mode, test 9) and whose red is ISOLATED (no other open
# PR shares it, so the systemic guard does NOT fire), must be LEFT OPEN and ALERTED
# — never closed — under the DEFAULT config. This is exactly the #4173/#4175 class:
# a vouched-for (armed) PR with a real-but-1-line-fixable red on its own branch.
# FAKE_BIN's gh stub returns nothing for `pr list`, so count_shared_red_prs → ISOLATED.
out_isolated=$(PATH="$FAKE_BIN:$PATH" GH_STUB_JSON_FILE="$STUB_JSON_STALE" \
    PR_TERMINAL_HOURS=6 PR_TERMINAL_FRESHNESS_MIN=10 \
    CHECK_PR=4173 bash "$DAEMON" 2>&1)

if echo "$out_isolated" | grep -q "ALERT-NOT-REAP (RESILIENT-379)"; then
    ok "armed+red+stale ISOLATED PR is alert-not-reaped by default (#4173/#4175 class)"
else
    fail "armed+red+stale isolated PR was NOT alert-not-reaped by default: $out_isolated"
fi
if echo "$out_isolated" | grep -q "WOULD close"; then
    fail "default mode produced a WOULD-close diagnostic for an armed PR (should alert, not reap)"
else
    ok "no WOULD-close diagnostic for armed PR under default (alert-not-reap) config"
fi

# Test 12 (source): the alert-not-reap guard + opt-in flag are present in source.
if grep -q "PR_TERMINAL_CLOSE_ARMED" "$DAEMON" \
   && grep -q "pr_terminal_alert_not_reaped" "$DAEMON" \
   && grep -q "ALERT-NOT-REAP" "$DAEMON"; then
    ok "RESILIENT-379 alert-not-reap guard present (PR_TERMINAL_CLOSE_ARMED + pr_terminal_alert_not_reaped)"
else
    fail "RESILIENT-379 alert-not-reap guard missing from source"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
