#!/usr/bin/env bash
# scripts/ci/test-queue-driver-push-rescue.sh — INFRA-1141
#
# Verifies the push-failure rescue path in queue-driver.sh resolve_dirty_pr():
#   1. git fetch origin $branch is called before --force-with-lease push
#   2. Push exit code is captured (not masked by pipe to tail)
#   3. dirty_pr_push_failed is emitted to ambient.jsonl on push failure
#   4. dirty_pr_push_failed is registered in EVENT_REGISTRY.yaml
#
# Static analysis only — we don't make live git or GitHub calls.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QD="$REPO_ROOT/scripts/coord/queue-driver.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

pass=0; total=0
check() {
  total=$((total+1))
  if "$@" >/dev/null 2>&1; then
    ok "$*"
    pass=$((pass+1))
  else
    fail "$*"
  fi
}

echo "=== INFRA-1141: push-rescue checks ==="

# 1. Script exists and is executable
check test -f "$QD"
check test -x "$QD"

# 2. fetch before push in the clean-rebase path
check grep -q 'git fetch origin.*branch.*quiet' "$QD"

# 3. Push output captured in variable (not piped to tail) — both paths
# Pattern: _push_out=$(...) appears twice (clean + dirty paths)
count=$(grep -c '_push_out=$(git push origin' "$QD" || true)
if [[ "$count" -ge 2 ]]; then
  ok "push output captured in variable (both paths, count=$count)"
  pass=$((pass+1))
else
  fail "push output not captured in variable (found $count, need >=2)"
fi
total=$((total+1))

# 4. Exit code checked after push — _push_rc=$? appears twice
count=$(grep -c '_push_rc=\$?' "$QD" || true)
if [[ "$count" -ge 2 ]]; then
  ok "push exit code checked (_push_rc=$? count=$count)"
  pass=$((pass+1))
else
  fail "push exit code not checked (found $count, need >=2)"
fi
total=$((total+1))

# 5. dirty_pr_push_failed emitted on failure
check grep -q 'dirty_pr_push_failed' "$QD"

# 6. phase field distinguishes clean vs dirty path
count=$(grep -c '"phase"' "$QD" || true)
if [[ "$count" -ge 2 ]]; then
  ok "phase field present in push_failed events (count=$count)"
  pass=$((pass+1))
else
  fail "phase field missing or only one (found $count, need >=2)"
fi
total=$((total+1))

# 7. dirty_pr_push_failed registered in EVENT_REGISTRY.yaml
check test -f "$REGISTRY"
check grep -q 'dirty_pr_push_failed' "$REGISTRY"

# 8. Registry entry has required fields
total=$((total+1))
if grep -A5 'dirty_pr_push_failed' "$REGISTRY" | grep -q 'fields_required'; then
  ok "dirty_pr_push_failed registry entry has fields_required"
  pass=$((pass+1))
else
  fail "dirty_pr_push_failed registry entry missing fields_required"
fi

echo ""
echo "=== Results: $pass/$total passed ==="
if [[ "$pass" -ne "$total" ]]; then
  exit 1
fi
echo "INFRA-1141: push-rescue validation complete."
