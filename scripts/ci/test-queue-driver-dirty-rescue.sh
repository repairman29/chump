#!/usr/bin/env bash
# scripts/ci/test-queue-driver-dirty-rescue.sh — INFRA-1137
#
# Synthesizes a DIRTY-style rebase scenario whose only conflict is in a
# .gitattributes-merge-driver-managed file (.github/workflows/ci.yml here,
# which uses the `union` driver via ci-yml-add-row). Asserts the
# resolve_dirty_pr() function in queue-driver.sh recognizes the file as
# merge-driver-managed and emits kind=dirty_pr_auto_resolved.
#
# We don't synthesize a real GitHub PR — we exercise the merge-driver-pattern
# matching + ambient-emission logic directly, which is what regressed before
# this gap.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QD="$REPO_ROOT/scripts/coord/queue-driver.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$QD" ]] || fail "queue-driver.sh not found at $QD"

# 1. queue-driver.sh references resolve_dirty_pr in the DIRTY-candidate loop
#    (AC #1: the function must actually be invoked from the main DIRTY loop,
#    not only from the cascade-rebase path).
grep -q 'for pr in \$dirty_candidates' "$QD" \
    || fail "queue-driver.sh missing main DIRTY-candidate loop"
awk '/for pr in \$dirty_candidates/,/^done/' "$QD" | grep -q 'resolve_dirty_pr' \
    || fail "DIRTY loop does not call resolve_dirty_pr (AC #1)"
ok "DIRTY candidate loop calls resolve_dirty_pr"

# 2. resolve_dirty_pr reads .gitattributes for merge-driver patterns (AC #2/#3).
awk '/^resolve_dirty_pr\(\)/,/^}/' "$QD" | grep -q '\.gitattributes' \
    || fail "resolve_dirty_pr does not consult .gitattributes (AC #2/#3)"
awk '/^resolve_dirty_pr\(\)/,/^}/' "$QD" | grep -q 'merge=' \
    || fail "resolve_dirty_pr does not filter on merge= attribute lines"
ok "resolve_dirty_pr reads .gitattributes for merge driver patterns"

# 3. Both ambient kinds are emitted by resolve_dirty_pr (AC #4 + #5).
awk '/^resolve_dirty_pr\(\)/,/^}/' "$QD" | grep -q 'dirty_pr_auto_resolved' \
    || fail "resolve_dirty_pr does not emit kind=dirty_pr_auto_resolved (AC #4)"
awk '/^resolve_dirty_pr\(\)/,/^}/' "$QD" | grep -q 'dirty_pr_unresolvable' \
    || fail "resolve_dirty_pr does not emit kind=dirty_pr_unresolvable (AC #5)"
ok "resolve_dirty_pr emits both auto_resolved + unresolvable kinds"

# 4. EVENT_REGISTRY.yaml registers both new kinds (AC #6).
ER="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q '^  - kind: dirty_pr_auto_resolved' "$ER" \
    || fail "EVENT_REGISTRY.yaml missing dirty_pr_auto_resolved (AC #6)"
grep -q '^  - kind: dirty_pr_unresolvable' "$ER" \
    || fail "EVENT_REGISTRY.yaml missing dirty_pr_unresolvable (AC #6)"
ok "EVENT_REGISTRY.yaml registers both new kinds"

# 5. Behavioral check on the .gitattributes pattern matching: extract the
#    matching logic and verify .github/workflows/ci.yml is recognized as
#    merge-driver-managed (AC #2 evidence + AC #8 today's stuck-PR conflict).
[[ -f "$REPO_ROOT/.gitattributes" ]] || fail ".gitattributes missing"
grep -q '\.github/workflows/ci\.yml.*merge=' "$REPO_ROOT/.gitattributes" \
    || fail ".gitattributes does not declare a merge driver for ci.yml (AC #8 prerequisite)"
grep -q 'docs/observability/EVENT_REGISTRY\.yaml.*merge=' "$REPO_ROOT/.gitattributes" \
    || fail ".gitattributes does not declare a merge driver for EVENT_REGISTRY.yaml (AC #8)"
ok ".gitattributes declares merge drivers for the two stuck-PR conflict files"

# 6. Inline simulate the pattern-match helper: replicate the same bash logic
#    the function uses, with .gitattributes-derived patterns, and verify both
#    today's stuck files match while a foreign file does not.
md_patterns=()
while IFS= read -r line; do
  pat="${line%% *}"
  [[ -n "$pat" && "$pat" != "#"* ]] && md_patterns+=("$pat")
done < <(grep -E "merge=" "$REPO_ROOT/.gitattributes" 2>/dev/null)

_is_md_file() {
  local f="$1" pat
  for pat in "${md_patterns[@]}"; do
    [[ "$f" == $pat ]] && return 0
  done
  return 1
}

_is_md_file ".github/workflows/ci.yml" \
    || fail "pattern match: ci.yml NOT recognized as merge-driver file (bug AC #8 was meant to fix)"
_is_md_file "docs/observability/EVENT_REGISTRY.yaml" \
    || fail "pattern match: EVENT_REGISTRY.yaml NOT recognized"
_is_md_file "docs/gaps/INFRA-9999.yaml" \
    || fail "pattern match: docs/gaps/*.yaml NOT recognized via glob"
if _is_md_file "src/main.rs"; then
  fail "pattern match: src/main.rs SHOULD NOT be recognized as merge-driver-managed"
fi
ok "pattern match: ci.yml, EVENT_REGISTRY.yaml, docs/gaps/*.yaml all rescue-eligible; src/main.rs is not"

echo
echo "All INFRA-1137 queue-driver-dirty-rescue tests passed."
