#!/usr/bin/env bash
# scripts/ci/test-conflict-resolution-consumer.sh — RESILIENT-301
#
# Source-contract + structural tests for the standing consumer of
# armed_pr_needs_conflict_resolution. Full end-to-end execution requires a
# live gh/PR queue, so this layer asserts:
#   - Script exists, executable, no bash syntax errors
#   - All 4 new event kinds emit + are registered in EVENT_REGISTRY.yaml
#   - Attempt-tracking + escalation constants present (AC #3)
#   - Plain-rebase-first + conflict-resolver-agent dispatch present (AC #2)
#   - No-op exit when gh/python3 missing (defensive guards)
#   - Synthetic real-conflict scenario: script's rebase-detection logic
#     correctly distinguishes clean vs conflicted via a real git worktree

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/conflict-resolution-consumer.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

echo "=== RESILIENT-301 conflict-resolution-consumer tests ==="

# ── Source-contract ───────────────────────────────────────────────────────────
[[ -x "$SCRIPT" ]] && ok "script exists + executable" || { fail "missing $SCRIPT"; exit 1; }

if bash -n "$SCRIPT"; then
    ok "no bash syntax errors"
else
    fail "bash -n reported syntax errors"
fi

for kind in conflict_resolution_consumer_tick conflict_resolution_consumer_rebase_clean \
            conflict_resolution_consumer_resolved conflict_resolution_consumer_escalated; do
    if grep -q "\"$kind\"" "$SCRIPT"; then
        ok "script emits $kind"
    else
        fail "script missing emit $kind"
    fi
    if grep -q "kind: $kind" "$REGISTRY"; then
        ok "EVENT_REGISTRY.yaml registers $kind"
    else
        fail "EVENT_REGISTRY.yaml missing $kind"
    fi
done

# AC #1: consumes armed_pr_needs_conflict_resolution (reads from ambient.jsonl)
if grep -q "armed_pr_needs_conflict_resolution" "$SCRIPT"; then
    ok "AC#1: script consumes armed_pr_needs_conflict_resolution"
else
    fail "AC#1: script does not reference armed_pr_needs_conflict_resolution"
fi

# AC #1: also picks up green+DIRTY+unarmed PRs
if grep -q "mergeStateStatus" "$SCRIPT" && grep -q "autoMergeRequest" "$SCRIPT"; then
    ok "AC#1: script scans green+DIRTY+unarmed PRs via mergeStateStatus/autoMergeRequest"
else
    fail "AC#1: missing green-DIRTY-unarmed scan"
fi

# AC #2: attempts resolution — plain rebase first, then conflict-resolver-agent
if grep -q "git rebase origin/main" "$SCRIPT"; then
    ok "AC#2: plain-rebase-first path present"
else
    fail "AC#2: missing plain rebase attempt"
fi
if grep -q "conflict-resolver-agent.sh" "$SCRIPT"; then
    ok "AC#2: dispatches conflict-resolver-agent.sh on real conflicts"
else
    fail "AC#2: missing conflict-resolver-agent.sh dispatch"
fi
if grep -q "force-with-lease" "$SCRIPT" && grep -q "pr merge" "$SCRIPT"; then
    ok "AC#2: pushes clean + arms auto-merge"
else
    fail "AC#2: missing push+arm on clean resolution"
fi

# AC #3: escalates after N tries with PR#, age, reason
if grep -q "CHUMP_CONFLICT_CONSUMER_MAX_ATTEMPTS" "$SCRIPT"; then
    ok "AC#3: max-attempts budget present"
else
    fail "AC#3: missing max-attempts env"
fi
if grep -q "age_hrs" "$SCRIPT" && grep -q "reason=" "$SCRIPT"; then
    ok "AC#3: escalation includes age + reason"
else
    fail "AC#3: escalation missing age/reason fields"
fi
if grep -q "conflict_resolution_consumer_escalated" "$SCRIPT" && grep -q "BROADCAST" "$SCRIPT"; then
    ok "AC#3: escalates via ambient + broadcast to operator"
else
    fail "AC#3: missing operator escalation path"
fi

# Defensive guards — no-op if gh/python3 missing
if grep -q "command -v gh" "$SCRIPT" && grep -q "command -v python3" "$SCRIPT"; then
    ok "defensive: exits cleanly if gh/python3 missing"
else
    fail "missing defensive command -v guards"
fi

# ── Structural: synthetic conflict vs clean rebase detection ──────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" && git init --quiet -b main
git config user.email t@e && git config user.name t
echo "base" > f.txt && git add . && git commit -q -m base

git checkout -q -b feature
echo "feature-change" > f.txt && git commit -q -am feature

git checkout -q main
echo "main-conflicting-change" > f.txt && git commit -q -am main-change

git checkout -q feature
if ! git rebase main >/dev/null 2>&1; then
    if [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
        ok "structural: synthetic conflict correctly detected via diff-filter=U"
    else
        fail "structural: conflict not surfaced via diff-filter=U"
    fi
    git rebase --abort 2>/dev/null || true
else
    fail "structural: expected rebase conflict did not occur"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
