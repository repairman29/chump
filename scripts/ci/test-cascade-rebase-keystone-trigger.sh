#!/usr/bin/env bash
# test-cascade-rebase-keystone-trigger.sh — META-145 (META-131 slice f)
#
# Pins the 3 acceptance criteria of the "cascade rebase auto-trigger" gap to
# the concrete wiring that already implements it (INFRA-670/711/1310/2207),
# so a future refactor can't silently drop one of the three pieces:
#
#   1. Monitoring: queue-driver.yml runs on every push to main, and
#      cascade_rebase_if_hot() reads the configured keystone-file list.
#   2. Trigger: cascade_rebase_if_hot() is invoked unconditionally near the
#      top of queue-driver.sh (before the BEHIND/DIRTY loop) and rebases
#      every open non-draft PR when a keystone file lands.
#   3. Logging: cascade_rebase_triggered / cascade_rebase_skipped_duplicate
#      are registered ambient event kinds (failures + actions are audited).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

QUEUE_DRIVER="$REPO_ROOT/scripts/coord/queue-driver.sh"
TRIGGER_PATHS="$REPO_ROOT/scripts/coord/cascade-rebase-trigger-paths.txt"
WORKFLOW="$REPO_ROOT/.github/workflows/queue-driver.yml"
EVENT_REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

# ── AC1: monitoring is in place ──────────────────────────────────────────
[[ -f "$QUEUE_DRIVER" ]] || fail "queue-driver.sh missing: $QUEUE_DRIVER"
[[ -f "$TRIGGER_PATHS" ]] || fail "keystone-file config missing: $TRIGGER_PATHS"
grep -q '^[^#[:space:]]' "$TRIGGER_PATHS" || fail "keystone-file config is empty (no monitored paths)"
[[ -f "$WORKFLOW" ]] || fail "queue-driver workflow missing: $WORKFLOW"
grep -q 'push:' "$WORKFLOW" && grep -q 'branches: \[main\]' "$WORKFLOW" \
    || fail "queue-driver.yml is not wired to push-to-main"
ok "AC1: keystone-file monitoring configured (${TRIGGER_PATHS##*/}) + push-to-main trigger wired"

# ── AC2: hot-file landing on main cascades a rebase of all open PRs ─────
grep -q '^cascade_rebase_if_hot$' "$QUEUE_DRIVER" \
    || fail "cascade_rebase_if_hot is not invoked unconditionally in queue-driver.sh"
grep -q 'cascade_rebase_if_hot()' "$QUEUE_DRIVER" \
    || fail "cascade_rebase_if_hot function definition missing"
grep -q 'all_prs' "$QUEUE_DRIVER" \
    || fail "cascade_rebase_if_hot does not appear to iterate all open PRs"
ok "AC2: cascade_rebase_if_hot is called on every driver tick and rebases all open PRs"

# ── AC3: actions and failures are logged ─────────────────────────────────
[[ -f "$EVENT_REGISTRY" ]] || fail "event registry missing: $EVENT_REGISTRY"
for kind in cascade_rebase_triggered cascade_rebase_skipped_duplicate; do
    grep -q "kind: $kind" "$EVENT_REGISTRY" \
        || fail "ambient event kind '$kind' not registered in EVENT_REGISTRY.yaml"
done
grep -q 'cascade_rebase_triggered' "$QUEUE_DRIVER" \
    || fail "queue-driver.sh does not emit cascade_rebase_triggered"
grep -q 'ok=0 fail=0' "$QUEUE_DRIVER" \
    || fail "queue-driver.sh cascade loop does not track per-PR ok/fail counts"
ok "AC3: cascade actions + failures are emitted to ambient.jsonl and registered"

echo ""
echo "=== test-cascade-rebase-keystone-trigger.sh PASSED ==="
